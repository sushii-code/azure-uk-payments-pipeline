-- Read-only test queries: paste the whole file, so every query can see @run_date
-- Change this date to check a different day
DECLARE @run_date DATE = '2026-10-30';
DECLARE @date_key INT = YEAR(@run_date) * 10000 + MONTH(@run_date) * 100 + DAY(@run_date);

-- Row counts per table for this date, to confirm each load step put data where it should
-- The dimension tables hold all dates, so they're counted in full
SELECT 'stg.payments' AS table_name, COUNT(*) AS row_count FROM stg.payments WHERE CAST(txn_timestamp AS DATE) = @run_date
UNION ALL SELECT 'dw.fx_rate', COUNT(*) FROM dw.fx_rate WHERE rate_date = @run_date
UNION ALL SELECT 'dw.dim_date', COUNT(*) FROM dw.dim_date WHERE date_key = @date_key
UNION ALL SELECT 'dw.dim_card (all)', COUNT(*) FROM dw.dim_card
UNION ALL SELECT 'dw.dim_merchant (all)', COUNT(*) FROM dw.dim_merchant
UNION ALL SELECT 'dw.fact_payment', COUNT(*) FROM dw.fact_payment WHERE date_key = @date_key
UNION ALL SELECT 'dw.reject_payment', COUNT(*) FROM dw.reject_payment WHERE run_date = @run_date
UNION ALL SELECT 'dw.load_audit', COUNT(*) FROM dw.load_audit WHERE run_date = @run_date;

-- Rejected rows grouped by reason, to compare with the dirty data the simulator planted
SELECT reason, COUNT(*) AS row_count
FROM dw.reject_payment
WHERE run_date = @run_date
GROUP BY reason
ORDER BY reason;

-- Flagged rows and distinct cards per flag, to compare with the fraud the simulator planted
-- COUNT(DISTINCT ...) ignores NULLs, so CASE with no ELSE only counts cards that have the flag
SELECT
    SUM(CAST(flag_high_amount AS INT)) AS high_amount_rows,
    SUM(CAST(flag_velocity AS INT)) AS velocity_rows,
    COUNT(DISTINCT CASE WHEN flag_velocity = 1 THEN card_key END) AS velocity_cards,
    SUM(CAST(flag_impossible_travel AS INT)) AS travel_rows,
    COUNT(DISTINCT CASE WHEN flag_impossible_travel = 1 THEN card_key END) AS travel_cards,
    SUM(CAST(is_suspicious AS INT)) AS suspicious_rows
FROM dw.fact_payment
WHERE date_key = @date_key;

-- The 10 biggest payments in GBP, which should be the planted high-amount fraud
SELECT TOP (10)
    f.transaction_id,
    f.txn_timestamp_utc,
    c.card_id,
    m.merchant_name,
    f.amount_original,
    f.currency,
    f.fx_rate,
    f.amount_gbp,
    f.flag_high_amount
FROM dw.fact_payment AS f
INNER JOIN dw.dim_card AS c
    ON c.card_key = f.card_key
INNER JOIN dw.dim_merchant AS m
    ON m.merchant_key = f.merchant_key
WHERE f.date_key = @date_key
ORDER BY f.amount_gbp DESC;

-- The most recent audit rows for this date, to confirm the load's own counts
SELECT TOP (5) *
FROM dw.load_audit
WHERE run_date = @run_date
ORDER BY audit_id DESC;
