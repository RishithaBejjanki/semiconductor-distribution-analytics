-- =====================================================================
-- PROJECT 6 - Multi-source POS ingestion: STAGE + LOAD (Snowflake)
-- Creates the landing area and loads the JSON files
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS STG;
CREATE SCHEMA IF NOT EXISTS CLEAN;
USE SCHEMA STG;

-- JSON files hold an array of submissions; strip the array so each submission is one row
CREATE OR REPLACE FILE FORMAT FF_POS_JSON TYPE = JSON STRIP_OUTER_ARRAY = TRUE;
CREATE OR REPLACE STAGE POS_STAGE FILE_FORMAT = FF_POS_JSON;

-- >>> Now upload the 64 files from data/sources/pos_feeds/ :
--     Snowsight > Data > Databases > CHANNEL_ANALYTICS > STG > Stages > POS_STAGE > "+ Files"
LIST @POS_STAGE;

-- Raw landing table: keep the original JSON untouched + where it came from + when
CREATE OR REPLACE TABLE RAW_POS_SUBMISSIONS (
    SRC VARIANT, FILE_NAME STRING, LOADED_AT TIMESTAMP_LTZ);

COPY INTO RAW_POS_SUBMISSIONS (SRC, FILE_NAME, LOADED_AT)
FROM (SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP() FROM @POS_STAGE)
PATTERN = '.*pos_.*[.]json';
-- Re-running COPY skips files already loaded (Snowflake load metadata) -> safe to schedule

-- Reference data (load with Snowsight "Load Data", header row skipped)
CREATE OR REPLACE TABLE CRM_ACCOUNTS (
    ACCOUNT_ID STRING, ACCOUNT_NAME STRING, DIST_CODE STRING, ERP_DISTRIBUTOR_ID STRING,
    REGION STRING, STATUS STRING);
CREATE OR REPLACE TABLE SKU_XREF (DIST_CODE STRING, DIST_SKU STRING, PART_NUMBER STRING);
-- >>> Load data/sources/crm_accounts.csv -> STG.CRM_ACCOUNTS and sku_xref.csv -> STG.SKU_XREF

SELECT COUNT(*) AS SUBMISSIONS, COUNT(DISTINCT FILE_NAME) AS FILES FROM RAW_POS_SUBMISSIONS;  -- expect 796 / 64
