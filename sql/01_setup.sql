-- Create the "stg" schema (a folder for tables) for raw data as it lands
-- EXEC is used because CREATE SCHEMA can't sit directly inside an IF
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');

-- Create the "dw" schema (data warehouse) for the clean tables that reports use
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');

-- Create a database user for Data Factory's managed identity, so it can sign in without a password
IF USER_ID('adf-ukpay-dev-e0vivl') IS NULL CREATE USER [adf-ukpay-dev-e0vivl] FROM EXTERNAL PROVIDER;

-- Let Data Factory load the staging tables, including emptying them before a new load
GRANT SELECT, INSERT, UPDATE, DELETE, ALTER ON SCHEMA::stg TO [adf-ukpay-dev-e0vivl];

-- Let Data Factory read the warehouse and run its stored procedures, but not change tables directly
GRANT SELECT, EXECUTE ON SCHEMA::dw TO [adf-ukpay-dev-e0vivl];
