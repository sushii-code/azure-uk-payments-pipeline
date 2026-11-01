-- Every table is only created if it's missing, so this script is safe to run again
-- Dimension tables come before fact_payment, because the fact table points to them

-- Staging table: the 16 silver Parquet columns, landed as they are
-- Everything allows NULL and there are no keys, so bad rows can land and be dealt with later
IF OBJECT_ID('stg.payments') IS NULL
CREATE TABLE stg.payments (
    transaction_id    NVARCHAR(50)    NULL,
    txn_timestamp     DATETIME2(0)    NULL,
    card_id           NVARCHAR(50)    NULL,
    customer_id       NVARCHAR(50)    NULL,
    card_home_country NVARCHAR(50)    NULL,
    merchant_id       NVARCHAR(50)    NULL,
    merchant_name     NVARCHAR(200)   NULL,
    merchant_category NVARCHAR(100)   NULL,
    merchant_country  NVARCHAR(50)    NULL,
    amount            DECIMAL(38, 18) NULL,
    currency          NVARCHAR(20)    NULL,
    channel           NVARCHAR(50)    NULL,
    status            NVARCHAR(50)    NULL,
    ingest_run_id     NVARCHAR(50)    NULL,
    source_file       NVARCHAR(400)   NULL,
    ingested_at_utc   NVARCHAR(50)    NULL
);

-- FX rates: how much of each currency 1 GBP buys on each date (GBP itself is stored as 1.0)
-- ecb_date is the day the ECB really published the rate, which differs on weekends
IF OBJECT_ID('dw.fx_rate') IS NULL
CREATE TABLE dw.fx_rate (
    rate_date  DATE           NOT NULL,
    currency   CHAR(3)        NOT NULL,
    gbp_to_ccy DECIMAL(18, 8) NOT NULL,
    ecb_date   DATE           NOT NULL,
    loaded_at  DATETIME2(0)   NOT NULL CONSTRAINT DF_fx_rate_loaded_at DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_fx_rate PRIMARY KEY (rate_date, currency)
);

-- Date dimension: one row per day, so reports can group by month, weekday and so on
IF OBJECT_ID('dw.dim_date') IS NULL
CREATE TABLE dw.dim_date (
    date_key   INT          NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,
    full_date  DATE         NOT NULL,
    day_name   NVARCHAR(10) NOT NULL,
    is_weekend BIT          NOT NULL,
    month_num  TINYINT      NOT NULL,
    month_name NVARCHAR(10) NOT NULL,
    year_num   SMALLINT     NOT NULL
);

-- Card dimension: one row per card
-- card_key is a small number made by the database; card_id is the ID from the source data
IF OBJECT_ID('dw.dim_card') IS NULL
CREATE TABLE dw.dim_card (
    card_key          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_dim_card PRIMARY KEY,
    card_id           NVARCHAR(50)       NOT NULL CONSTRAINT UQ_dim_card_card_id UNIQUE,
    customer_id       NVARCHAR(50)       NULL,
    card_home_country NVARCHAR(50)       NULL
);

-- Merchant dimension: one row per merchant
IF OBJECT_ID('dw.dim_merchant') IS NULL
CREATE TABLE dw.dim_merchant (
    merchant_key      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_dim_merchant PRIMARY KEY,
    merchant_id       NVARCHAR(50)       NOT NULL CONSTRAINT UQ_dim_merchant_merchant_id UNIQUE,
    merchant_name     NVARCHAR(200)      NULL,
    merchant_category NVARCHAR(100)      NULL,
    merchant_country  NVARCHAR(50)       NULL
);

-- Fact table: one row per clean payment, with its GBP amount and fraud flags
-- The foreign keys stop a payment from pointing to a date, card or merchant that doesn't exist
-- is_suspicious is calculated by the database, so it can never disagree with the flags
IF OBJECT_ID('dw.fact_payment') IS NULL
CREATE TABLE dw.fact_payment (
    transaction_id         NVARCHAR(50)   NOT NULL CONSTRAINT PK_fact_payment PRIMARY KEY,
    date_key               INT            NOT NULL CONSTRAINT FK_fact_payment_date REFERENCES dw.dim_date (date_key),
    card_key               INT            NOT NULL CONSTRAINT FK_fact_payment_card REFERENCES dw.dim_card (card_key),
    merchant_key           INT            NOT NULL CONSTRAINT FK_fact_payment_merchant REFERENCES dw.dim_merchant (merchant_key),
    txn_timestamp_utc      DATETIME2(0)   NOT NULL,
    amount_original        DECIMAL(18, 2) NOT NULL,
    currency               CHAR(3)        NOT NULL,
    fx_rate                DECIMAL(18, 8) NOT NULL,
    amount_gbp             DECIMAL(18, 2) NOT NULL,
    channel                NVARCHAR(50)   NULL,
    status                 NVARCHAR(50)   NULL,
    flag_high_amount       BIT            NOT NULL,
    flag_velocity          BIT            NOT NULL,
    flag_impossible_travel BIT            NOT NULL,
    is_suspicious AS (
        CASE
            WHEN flag_high_amount = 1 OR flag_velocity = 1 OR flag_impossible_travel = 1 THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END
    ),
    ingest_run_id          NVARCHAR(50)   NULL,
    loaded_at              DATETIME2(0)   NOT NULL CONSTRAINT DF_fact_payment_loaded_at DEFAULT SYSUTCDATETIME()
);

-- Reject table: rows kept out of the fact table, and why
-- Raw values are stored as text, so any value can be kept exactly as it looked
IF OBJECT_ID('dw.reject_payment') IS NULL
CREATE TABLE dw.reject_payment (
    run_date          DATE          NOT NULL,
    transaction_id    NVARCHAR(50)  NULL,
    reason            NVARCHAR(50)  NOT NULL,
    raw_txn_timestamp NVARCHAR(50)  NULL,
    raw_amount        NVARCHAR(60)  NULL,
    raw_currency      NVARCHAR(20)  NULL,
    rejected_at       DATETIME2(0)  NOT NULL CONSTRAINT DF_reject_payment_rejected_at DEFAULT SYSUTCDATETIME()
);

-- Audit table: one row for every load attempt, including failures, so there's a history of runs
IF OBJECT_ID('dw.load_audit') IS NULL
CREATE TABLE dw.load_audit (
    audit_id                 INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_load_audit PRIMARY KEY,
    run_date                 DATE               NOT NULL,
    rows_staged              INT                NULL,
    rows_loaded              INT                NULL,
    rows_rejected            INT                NULL,
    rows_flagged_high_amount INT                NULL,
    rows_flagged_velocity    INT                NULL,
    rows_flagged_travel      INT                NULL,
    started_at               DATETIME2(0)       NOT NULL,
    finished_at              DATETIME2(0)       NULL,
    status                   NVARCHAR(20)       NOT NULL
);
