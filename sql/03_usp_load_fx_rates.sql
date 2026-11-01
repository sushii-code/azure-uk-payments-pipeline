-- Stored procedure: loads one day's FX rates from the Frankfurter JSON text
-- CREATE OR ALTER makes this file safe to run again, and it must be the only statement in the file
CREATE OR ALTER PROCEDURE dw.usp_load_fx_rates
    @run_date DATE,
    @payload  NVARCHAR(MAX)
AS
BEGIN
    -- Hide "rows affected" messages, and undo everything automatically if a serious error happens
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        -- Stop early if the text isn't JSON, because nothing below could read it
        IF @payload IS NULL OR ISJSON(@payload) = 0
            THROW 50001, 'usp_load_fx_rates: the payload is not valid JSON.', 1;

        -- Stop if there are no rates, because deleting the old rates would leave the day empty
        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@payload, '$.rates'))
            THROW 50002, 'usp_load_fx_rates: the JSON has no rates.', 1;

        -- Stop if the rates aren't based on GBP, because every GBP amount would be wrong
        IF ISNULL(JSON_VALUE(@payload, '$.base'), '') <> 'GBP'
            THROW 50003, 'usp_load_fx_rates: the JSON base currency is not GBP.', 1;

        -- Read the date the ECB really published these rates (it differs on weekends)
        DECLARE @ecb_date DATE = TRY_CONVERT(DATE, JSON_VALUE(@payload, '$.date'));

        -- Stop if that date is missing or unreadable
        IF @ecb_date IS NULL
            THROW 50004, 'usp_load_fx_rates: the JSON has no valid date.', 1;

        -- Stop if any rate is unreadable or not above zero, because amounts are divided by it
        IF EXISTS (
            SELECT 1
            FROM OPENJSON(@payload, '$.rates')
            WHERE ISNULL(TRY_CONVERT(DECIMAL(18, 8), [value]), 0) <= 0
        )
            THROW 50005, 'usp_load_fx_rates: the JSON has a rate that is invalid or not above zero.', 1;

        -- The delete and insert below succeed or fail together
        BEGIN TRANSACTION;

        -- Remove this date's old rates, so running the load again doesn't create duplicates
        DELETE FROM dw.fx_rate
        WHERE rate_date = @run_date;

        -- Add one row per currency from the JSON, for example {"EUR": 1.1993} becomes EUR and 1.1993
        -- GBP is skipped here in case the JSON includes it, because it's added separately below
        INSERT INTO dw.fx_rate (rate_date, currency, gbp_to_ccy, ecb_date)
        SELECT @run_date, UPPER(r.[key]), TRY_CONVERT(DECIMAL(18, 8), r.[value]), @ecb_date
        FROM OPENJSON(@payload, '$.rates') AS r
        WHERE UPPER(r.[key]) <> 'GBP';

        -- Add GBP at 1.0, so GBP payments can use the same calculation as other currencies
        INSERT INTO dw.fx_rate (rate_date, currency, gbp_to_ccy, ecb_date)
        VALUES (@run_date, 'GBP', 1.0, @ecb_date);

        -- Everything worked, so save it
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Something failed: undo any changes, then pass the error on so ADF shows the run as failed
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
