-- Compares warehouse counts with the answers predicted independently in Python
-- All 14 checks PASS for 2026-10-30
-- It's one query because the portal Query editor only shows the last result set
-- The dim_card and dim_merchant expected values only hold while the warehouse contains this one date
SELECT
    check_name,
    actual,
    expected,
    -- PASS only when the warehouse count equals the predicted count
    CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    -- Rows in staging: the 2,000 CSV rows minus the 6 bad timestamps rejected by the ADF copy
    SELECT 'staged rows' AS check_name, (SELECT COUNT(*) FROM stg.payments WHERE CAST(txn_timestamp AS DATE) = '2026-10-30') AS actual, 1994 AS expected

    -- FX rates: the 6 currencies from the feed plus GBP
    UNION ALL SELECT 'fx rates', (SELECT COUNT(*) FROM dw.fx_rate WHERE rate_date = '2026-10-30'), 7

    -- Clean rows that reached the fact table
    UNION ALL SELECT 'fact rows loaded', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030), 1964

    -- Rejected rows, by reason
    UNION ALL SELECT 'rejected duplicate', (SELECT COUNT(*) FROM dw.reject_payment WHERE run_date = '2026-10-30' AND reason = 'duplicate'), 20
    UNION ALL SELECT 'rejected missing_amount', (SELECT COUNT(*) FROM dw.reject_payment WHERE run_date = '2026-10-30' AND reason = 'missing_amount'), 10

    -- Planted fraud: high amounts
    UNION ALL SELECT 'high amount rows', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030 AND flag_high_amount = 1), 10

    -- Planted fraud: many payments in a short time, counted as rows and as cards
    UNION ALL SELECT 'velocity rows', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030 AND flag_velocity = 1), 23
    UNION ALL SELECT 'velocity cards', (SELECT COUNT(DISTINCT card_key) FROM dw.fact_payment WHERE date_key = 20261030 AND flag_velocity = 1), 3

    -- Planted fraud: paying in GB and then abroad too soon, counted as rows and as cards
    UNION ALL SELECT 'travel rows', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030 AND flag_impossible_travel = 1), 3
    UNION ALL SELECT 'travel cards', (SELECT COUNT(DISTINCT card_key) FROM dw.fact_payment WHERE date_key = 20261030 AND flag_impossible_travel = 1), 3

    -- Rows with any fraud flag
    UNION ALL SELECT 'suspicious rows', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030 AND is_suspicious = 1), 36

    -- Dimension sizes
    UNION ALL SELECT 'dim_card', (SELECT COUNT(*) FROM dw.dim_card), 490
    UNION ALL SELECT 'dim_merchant', (SELECT COUNT(*) FROM dw.dim_merchant), 119

    -- Lowercase currencies left in the fact table
    -- Comparing bytes makes the check case-sensitive, because a normal = ignores case in this database
    UNION ALL SELECT 'lowercase currency left', (SELECT COUNT(*) FROM dw.fact_payment WHERE date_key = 20261030 AND CAST(currency AS VARBINARY(10)) <> CAST(UPPER(currency) AS VARBINARY(10))), 0
) AS checks;
