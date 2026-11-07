-- Stored procedure: lists which dates still need loading, oldest first
-- This is a gap-aware watermark. A simple watermark only remembers the latest date loaded,
-- so a failed day in the middle would be forgotten. This one checks every day instead:
-- any day from the first successful load up to @up_to_date with no 'succeeded' audit row is returned
-- @max_days limits one run, so a long gap can't use up the free database's monthly allowance in one go
-- CREATE OR ALTER makes this file safe to run again, and it must be the only statement in the file
CREATE OR ALTER PROCEDURE dw.usp_get_dates_to_load
    @up_to_date DATE,
    @max_days   INT = 7
AS
BEGIN
    -- Hide "rows affected" messages, which aren't useful here
    SET NOCOUNT ON;

    -- Start from the first successful load; if there are none yet, just check @up_to_date
    DECLARE @first DATE = ISNULL(
        (SELECT MIN(run_date) FROM dw.load_audit WHERE status = 'succeeded'),
        @up_to_date
    );

    -- Build a list of every day from @first to @up_to_date
    -- This CTE refers to itself, adding one day each time until it reaches the end date
    WITH all_days AS (
        SELECT @first AS run_date
        UNION ALL
        SELECT DATEADD(DAY, 1, run_date)
        FROM all_days
        WHERE run_date < @up_to_date
    )
    -- Keep only the days with no successful load, as yyyy-MM-dd text that ADF can pass to a pipeline
    -- MAXRECURSION raises SQL Server's default limit of 100 repeats, so long date ranges still work
    SELECT TOP (@max_days)
        CONVERT(CHAR(10), d.run_date, 23) AS run_date
    FROM all_days AS d
    WHERE NOT EXISTS (
        SELECT 1
        FROM dw.load_audit AS a
        WHERE a.run_date = d.run_date
          AND a.status = 'succeeded'
    )
    ORDER BY d.run_date
    OPTION (MAXRECURSION 1000);
END;
