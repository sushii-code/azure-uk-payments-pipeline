-- Stored procedure: cleans one day of staged payments and loads the warehouse tables
-- CREATE OR ALTER makes this file safe to run again, and it must be the only statement in the file
CREATE OR ALTER PROCEDURE dw.usp_load_payments
    @run_date DATE
AS
BEGIN
    -- Hide "rows affected" messages, and undo everything automatically if a serious error happens
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Remember the start time for the audit row
    DECLARE @started_at DATETIME2(0) = SYSUTCDATETIME();

    -- Turn the date into the yyyymmdd number used by dim_date, for example 20261030
    DECLARE @date_key INT = YEAR(@run_date) * 10000 + MONTH(@run_date) * 100 + DAY(@run_date);

    -- These hold the counts for the audit row and the final result
    DECLARE
        @rows_staged   INT = 0,
        @rows_loaded   INT = 0,
        @rows_rejected INT = 0,
        @rows_high     INT = 0,
        @rows_velocity INT = 0,
        @rows_travel   INT = 0;

    BEGIN TRY
        -- FX must load first, because amounts can't be converted to GBP without rates
        IF NOT EXISTS (SELECT 1 FROM dw.fx_rate WHERE rate_date = @run_date)
            THROW 50011, 'usp_load_payments: no FX rates for this run_date. Run usp_load_fx_rates first.', 1;

        -- Everything from here until COMMIT succeeds or fails together
        BEGIN TRANSACTION;

        -- Step 1: number the copies of each transaction_id and tidy the currency code
        -- Rank 1 is the copy we keep, preferring one with an amount, then the newest
        SELECT
            s.*,
            UPPER(TRIM(s.currency)) AS currency_clean,
            ROW_NUMBER() OVER (
                PARTITION BY s.transaction_id
                ORDER BY CASE WHEN s.amount IS NULL THEN 1 ELSE 0 END, s.ingested_at_utc DESC
            ) AS copy_number
        INTO #staged
        FROM stg.payments AS s
        WHERE CAST(s.txn_timestamp AS DATE) = @run_date;

        -- Count what we received
        SET @rows_staged = (SELECT COUNT(*) FROM #staged);

        -- Stop if nothing was staged, because the deletes below would wipe a good earlier load
        IF @rows_staged = 0
            THROW 50012, 'usp_load_payments: stg.payments has no rows for this run_date.', 1;

        -- Step 2: look up each row's FX rate and decide if it should be rejected
        -- CASE stops at the first match, so each row gets exactly one reason
        -- Rows with no reason (reject_reason is NULL) are the clean rows
        SELECT
            s.*,
            fx.gbp_to_ccy,
            CASE
                WHEN s.transaction_id IS NULL OR s.card_id IS NULL OR s.merchant_id IS NULL THEN 'missing_key'
                WHEN s.copy_number > 1 THEN 'duplicate'
                WHEN s.amount IS NULL THEN 'missing_amount'
                WHEN fx.currency IS NULL THEN 'unknown_currency'
            END AS reject_reason
        INTO #checked
        FROM #staged AS s
        LEFT JOIN dw.fx_rate AS fx
            ON fx.rate_date = @run_date
           AND fx.currency = s.currency_clean;

        -- Step 3: remove this date's earlier results, so running the load again gives the same answer
        DELETE FROM dw.reject_payment
        WHERE run_date = @run_date;

        DELETE FROM dw.fact_payment
        WHERE date_key = @date_key;

        -- Step 4: save the rejected rows, with their raw values as text
        INSERT INTO dw.reject_payment (run_date, transaction_id, reason, raw_txn_timestamp, raw_amount, raw_currency)
        SELECT
            @run_date,
            transaction_id,
            reject_reason,
            CONVERT(NVARCHAR(50), txn_timestamp, 126),
            CONVERT(NVARCHAR(60), amount),
            currency
        FROM #checked
        WHERE reject_reason IS NOT NULL;

        -- Count the rejected rows
        SET @rows_rejected = @@ROWCOUNT;

        -- Step 5: add this date to dim_date if it isn't there yet
        -- DATENAME gives the same answer whichever day the server treats as the start of the week
        IF NOT EXISTS (SELECT 1 FROM dw.dim_date WHERE date_key = @date_key)
            INSERT INTO dw.dim_date (date_key, full_date, day_name, is_weekend, month_num, month_name, year_num)
            VALUES (
                @date_key,
                @run_date,
                DATENAME(WEEKDAY, @run_date),
                CASE WHEN DATENAME(WEEKDAY, @run_date) IN ('Saturday', 'Sunday') THEN 1 ELSE 0 END,
                MONTH(@run_date),
                DATENAME(MONTH, @run_date),
                YEAR(@run_date)
            );

        -- Step 6: add new cards and update changed ones (type 1 means we keep only the latest values)
        -- The source picks one row per card, because MERGE fails if a card appears twice
        -- EXCEPT is a simple way to compare values that may be NULL
        MERGE dw.dim_card WITH (HOLDLOCK) AS target
        USING (
            SELECT card_id, customer_id, card_home_country
            FROM (
                SELECT
                    card_id,
                    customer_id,
                    card_home_country,
                    ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY txn_timestamp DESC, transaction_id DESC) AS newest
                FROM #checked
                WHERE reject_reason IS NULL
            ) AS ranked
            WHERE newest = 1
        ) AS source
            ON target.card_id = source.card_id
        WHEN MATCHED AND EXISTS (
            SELECT source.customer_id, source.card_home_country
            EXCEPT
            SELECT target.customer_id, target.card_home_country
        ) THEN
            UPDATE SET
                customer_id = source.customer_id,
                card_home_country = source.card_home_country
        WHEN NOT MATCHED THEN
            INSERT (card_id, customer_id, card_home_country)
            VALUES (source.card_id, source.customer_id, source.card_home_country);

        -- Step 7: do the same for merchants
        MERGE dw.dim_merchant WITH (HOLDLOCK) AS target
        USING (
            SELECT merchant_id, merchant_name, merchant_category, merchant_country
            FROM (
                SELECT
                    merchant_id,
                    merchant_name,
                    merchant_category,
                    merchant_country,
                    ROW_NUMBER() OVER (PARTITION BY merchant_id ORDER BY txn_timestamp DESC, transaction_id DESC) AS newest
                FROM #checked
                WHERE reject_reason IS NULL
            ) AS ranked
            WHERE newest = 1
        ) AS source
            ON target.merchant_id = source.merchant_id
        WHEN MATCHED AND EXISTS (
            SELECT source.merchant_name, source.merchant_category, source.merchant_country
            EXCEPT
            SELECT target.merchant_name, target.merchant_category, target.merchant_country
        ) THEN
            UPDATE SET
                merchant_name = source.merchant_name,
                merchant_category = source.merchant_category,
                merchant_country = source.merchant_country
        WHEN NOT MATCHED THEN
            INSERT (merchant_id, merchant_name, merchant_category, merchant_country)
            VALUES (source.merchant_id, source.merchant_name, source.merchant_category, source.merchant_country);

        -- Step 8: find velocity windows: 10-minute periods, starting at a payment, with 6+ payments on that card
        SELECT DISTINCT
            w.card_id,
            w.txn_timestamp AS window_start,
            DATEADD(MINUTE, 10, w.txn_timestamp) AS window_end
        INTO #velocity_windows
        FROM #checked AS w
        WHERE w.reject_reason IS NULL
          AND (
              SELECT COUNT(*)
              FROM #checked AS other
              WHERE other.reject_reason IS NULL
                AND other.card_id = w.card_id
                AND other.txn_timestamp >= w.txn_timestamp
                AND other.txn_timestamp <= DATEADD(MINUTE, 10, w.txn_timestamp)
          ) >= 6;

        -- Step 9: load the facts, working out the GBP amount and the three fraud flags for each row
        -- CROSS APPLY calculates amount_gbp once, so the flag and the column always agree
        INSERT INTO dw.fact_payment (
            transaction_id,
            date_key,
            card_key,
            merchant_key,
            txn_timestamp_utc,
            amount_original,
            currency,
            fx_rate,
            amount_gbp,
            channel,
            status,
            flag_high_amount,
            flag_velocity,
            flag_impossible_travel,
            ingest_run_id
        )
        SELECT
            c.transaction_id,
            @date_key,
            card.card_key,
            merchant.merchant_key,
            c.txn_timestamp,
            CAST(c.amount AS DECIMAL(18, 2)),
            c.currency_clean,
            c.gbp_to_ccy,
            gbp.amount_gbp,
            c.channel,
            c.status,
            -- High amount: worth more than 2,000 GBP
            CASE WHEN gbp.amount_gbp > 2000 THEN 1 ELSE 0 END,
            -- Velocity: this payment is inside one of the card's velocity windows
            CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM #velocity_windows AS v
                    WHERE v.card_id = c.card_id
                      AND c.txn_timestamp >= v.window_start
                      AND c.txn_timestamp <= v.window_end
                ) THEN 1
                ELSE 0
            END,
            -- Impossible travel: paid outside GB, and the same card paid in GB in the previous 60 minutes
            CASE
                WHEN c.merchant_country <> 'GB' AND EXISTS (
                    SELECT 1
                    FROM #checked AS earlier
                    WHERE earlier.reject_reason IS NULL
                      AND earlier.card_id = c.card_id
                      AND earlier.merchant_country = 'GB'
                      AND earlier.txn_timestamp < c.txn_timestamp
                      AND earlier.txn_timestamp >= DATEADD(MINUTE, -60, c.txn_timestamp)
                ) THEN 1
                ELSE 0
            END,
            c.ingest_run_id
        FROM #checked AS c
        INNER JOIN dw.dim_card AS card
            ON card.card_id = c.card_id
        INNER JOIN dw.dim_merchant AS merchant
            ON merchant.merchant_id = c.merchant_id
        CROSS APPLY (
            SELECT CAST(ROUND(c.amount / c.gbp_to_ccy, 2) AS DECIMAL(18, 2)) AS amount_gbp
        ) AS gbp
        WHERE c.reject_reason IS NULL;

        -- Count the rows that were loaded
        SET @rows_loaded = @@ROWCOUNT;

        -- Count the flagged rows for the audit row
        SELECT
            @rows_high = SUM(CAST(flag_high_amount AS INT)),
            @rows_velocity = SUM(CAST(flag_velocity AS INT)),
            @rows_travel = SUM(CAST(flag_impossible_travel AS INT))
        FROM dw.fact_payment
        WHERE date_key = @date_key;

        -- Step 10: record this successful load in the audit table
        INSERT INTO dw.load_audit (
            run_date,
            rows_staged,
            rows_loaded,
            rows_rejected,
            rows_flagged_high_amount,
            rows_flagged_velocity,
            rows_flagged_travel,
            started_at,
            finished_at,
            status
        )
        VALUES (
            @run_date,
            @rows_staged,
            @rows_loaded,
            @rows_rejected,
            @rows_high,
            @rows_velocity,
            @rows_travel,
            @started_at,
            SYSUTCDATETIME(),
            'succeeded'
        );

        -- Everything worked, so save it all
        COMMIT TRANSACTION;

        -- Show the counts to whoever ran the procedure
        SELECT
            @run_date AS run_date,
            @rows_staged AS rows_staged,
            @rows_loaded AS rows_loaded,
            @rows_rejected AS rows_rejected,
            @rows_high AS rows_flagged_high_amount,
            @rows_velocity AS rows_flagged_velocity,
            @rows_travel AS rows_flagged_travel;
    END TRY
    BEGIN CATCH
        -- Something failed: undo all the changes from this run
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Record the failure after the undo, otherwise the audit row would be undone too
        INSERT INTO dw.load_audit (run_date, started_at, finished_at, status)
        VALUES (@run_date, @started_at, SYSUTCDATETIME(), 'failed');

        -- Pass the error on, so ADF shows the run as failed
        THROW;
    END CATCH
END;
