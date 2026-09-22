-- =====================================================================
-- PROJECT 6 - PARSE, RESOLVE RESUBMISSIONS, VALIDATE
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;
USE SCHEMA STG;

-- 1) One row per submission (header), standardized, with latest-version flag
CREATE OR REPLACE VIEW VW_SUBMISSION_HEADER AS
WITH parsed AS (
    SELECT SRC:submission_id::STRING                               AS SUBMISSION_ID,
           UPPER(TRIM(SRC:dist_code::STRING))                      AS DIST_CODE,
           COALESCE(TRY_TO_DATE(SRC:report_week::STRING, 'YYYY-MM-DD'),
                    TRY_TO_DATE(SRC:report_week::STRING, 'MM/DD/YYYY')) AS REPORT_WEEK,   -- two date formats
           SRC:submitted_at::TIMESTAMP_NTZ                         AS SUBMITTED_AT,
           SRC:control_total_qty::NUMBER                           AS CONTROL_TOTAL_QTY,
           ARRAY_SIZE(SRC:lines)                                   AS LINE_COUNT,
           FILE_NAME, LOADED_AT
    FROM RAW_POS_SUBMISSIONS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SRC:submission_id::STRING ORDER BY LOADED_AT DESC) = 1  -- same file loaded twice
)
SELECT *,
       ROW_NUMBER() OVER (PARTITION BY DIST_CODE, REPORT_WEEK ORDER BY SUBMITTED_AT DESC) = 1 AS IS_LATEST
FROM parsed;

-- 2) One row per submitted line (FLATTEN the JSON array)
CREATE OR REPLACE VIEW VW_POS_LINES AS
SELECT r.SRC:submission_id::STRING                           AS SUBMISSION_ID,
       l.INDEX                                               AS LINE_NO,
       UPPER(TRIM(l.VALUE:sku::STRING))                      AS DIST_SKU,
       TRY_TO_NUMBER(l.VALUE:qty::STRING)                    AS QTY,          -- "N/A" -> NULL
       TRY_TO_DECIMAL(l.VALUE:resale_usd::STRING, 14, 2)     AS RESALE_USD,
       l.VALUE:ship_to_country::STRING                       AS SHIP_TO_COUNTRY
FROM RAW_POS_SUBMISSIONS r,
     LATERAL FLATTEN(INPUT => r.SRC:lines) l;

-- 3) Validation: every line gets exactly one status
CREATE OR REPLACE VIEW VW_POS_LINES_VALIDATED AS
WITH active_crm AS (
    SELECT UPPER(TRIM(DIST_CODE)) AS DIST_CODE, ERP_DISTRIBUTOR_ID
    FROM CRM_ACCOUNTS WHERE STATUS = 'Active'
),
xref AS (
    SELECT UPPER(TRIM(DIST_CODE)) AS DIST_CODE, UPPER(TRIM(DIST_SKU)) AS DIST_SKU, PART_NUMBER FROM SKU_XREF
),
joined AS (
    SELECT l.*, h.DIST_CODE, h.REPORT_WEEK, h.IS_LATEST,
           a.ERP_DISTRIBUTOR_ID AS DISTRIBUTOR_ID,
           x.PART_NUMBER,
           ROW_NUMBER() OVER (PARTITION BY l.SUBMISSION_ID, l.DIST_SKU, l.QTY, l.RESALE_USD, l.SHIP_TO_COUNTRY
                              ORDER BY l.LINE_NO) AS DUP_RN
    FROM VW_POS_LINES l
    JOIN VW_SUBMISSION_HEADER h ON l.SUBMISSION_ID = h.SUBMISSION_ID
    LEFT JOIN active_crm a      ON h.DIST_CODE = a.DIST_CODE
    LEFT JOIN xref x            ON h.DIST_CODE = x.DIST_CODE AND l.DIST_SKU = x.DIST_SKU
)
SELECT *,
       CASE WHEN NOT IS_LATEST           THEN 'SUPERSEDED'
            WHEN DISTRIBUTOR_ID IS NULL  THEN 'REJECTED: unknown distributor'
            WHEN REPORT_WEEK IS NULL     THEN 'REJECTED: invalid report week'
            WHEN QTY IS NULL             THEN 'REJECTED: invalid quantity'
            WHEN PART_NUMBER IS NULL     THEN 'REJECTED: unmapped SKU'
            WHEN DUP_RN > 1              THEN 'REJECTED: duplicate line'
            ELSE 'ACCEPTED' END AS STATUS
FROM joined;

-- Quarantine: what goes back to the distributor / master-data team
CREATE OR REPLACE VIEW VW_POS_REJECTS AS
SELECT STATUS, SUBMISSION_ID, DIST_CODE, REPORT_WEEK, DIST_SKU, QTY, RESALE_USD, SHIP_TO_COUNTRY
FROM VW_POS_LINES_VALIDATED
WHERE STATUS LIKE 'REJECTED%';

SELECT STATUS, COUNT(*) AS LINES FROM VW_POS_LINES_VALIDATED GROUP BY 1 ORDER BY 2 DESC;
-- expect ACCEPTED 45,008 | SUPERSEDED 1,037 | duplicate 146 | unmapped SKU 51 | invalid qty 19
