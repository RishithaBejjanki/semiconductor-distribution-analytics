-- =====================================================================
-- PROJECT 4 - Weekly Distribution Ops Reporting Pack (Snowflake SQL)
-- Prerequisite: Project 1 loaded (RAW tables + MART views).
-- Builds the RPT schema: one view per report in the weekly pack.
-- Business rules are documented in requirements_spec.md.
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS RPT;

-- ---------------------------------------------------------------------
-- R0. Line-level helper: when did each order line become fully shipped?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW RPT.VW_ORDER_LINE_STATUS AS
WITH ship_cum AS (
    SELECT ORDER_ID, LINE_ID, SHIP_DATE,
           SUM(QTY_SHIPPED) OVER (PARTITION BY ORDER_ID, LINE_ID
                                  ORDER BY SHIP_DATE, SHIPMENT_ID
                                  ROWS UNBOUNDED PRECEDING) AS CUM_QTY_SHIPPED
    FROM RAW.FACT_SHIPMENTS
)
SELECT o.ORDER_ID, o.LINE_ID, o.DISTRIBUTOR_ID, o.PART_NUMBER, p.PRODUCT_FAMILY,
       o.ORDER_DATE, o.REQUEST_DATE, o.SCHEDULED_SHIP_DATE, o.ORDER_QTY, o.UNIT_PRICE,
       o.ORDER_QTY * o.UNIT_PRICE                                        AS LINE_VALUE,
       MIN(IFF(sc.CUM_QTY_SHIPPED >= o.ORDER_QTY, sc.SHIP_DATE, NULL))  AS FULL_SHIP_DATE,
       COALESCE(MAX(sc.CUM_QTY_SHIPPED), 0)                              AS QTY_SHIPPED_TO_DATE
FROM RAW.FACT_ORDERS o
JOIN RAW.DIM_PRODUCT p ON o.PART_NUMBER = p.PART_NUMBER
LEFT JOIN ship_cum sc ON o.ORDER_ID = sc.ORDER_ID AND o.LINE_ID = sc.LINE_ID
GROUP BY o.ORDER_ID, o.LINE_ID, o.DISTRIBUTOR_ID, o.PART_NUMBER, p.PRODUCT_FAMILY,
         o.ORDER_DATE, o.REQUEST_DATE, o.SCHEDULED_SHIP_DATE, o.ORDER_QTY, o.UNIT_PRICE;

-- R1. Weekly backlog waterfall: Begin + Bookings - Shipments = End
--     (distributor x product family x week)
CREATE OR REPLACE VIEW RPT.VW_BACKLOG_WATERFALL_WEEKLY AS
WITH weeks AS (
    SELECT DISTINCT WEEK_START, DATEADD('day', 6, WEEK_START) AS WEEK_END
    FROM RAW.DIM_DATE
    WHERE WEEK_START BETWEEN '2024-01-01' AND '2026-06-22'
),
families AS (SELECT DISTINCT PRODUCT_FAMILY FROM RAW.DIM_PRODUCT),
spine AS (            -- every week x distributor x family, so weeks with no activity still appear
    SELECT w.WEEK_START, w.WEEK_END, d.DISTRIBUTOR_ID, f.PRODUCT_FAMILY
    FROM weeks w CROSS JOIN RAW.DIM_DISTRIBUTOR d CROSS JOIN families f
),
bookings AS (
    SELECT DATE_TRUNC('week', ORDER_DATE) AS WEEK_START, DISTRIBUTOR_ID, PRODUCT_FAMILY,
           SUM(LINE_VALUE) AS BOOKINGS
    FROM RPT.VW_ORDER_LINE_STATUS
    GROUP BY 1, 2, 3
),
shipments AS (
    SELECT DATE_TRUNC('week', s.SHIP_DATE) AS WEEK_START, o.DISTRIBUTOR_ID, p.PRODUCT_FAMILY,
           SUM(s.QTY_SHIPPED * o.UNIT_PRICE) AS SHIPMENTS
    FROM RAW.FACT_SHIPMENTS s
    JOIN RAW.FACT_ORDERS o  ON s.ORDER_ID = o.ORDER_ID AND s.LINE_ID = o.LINE_ID
    JOIN RAW.DIM_PRODUCT p  ON o.PART_NUMBER = p.PART_NUMBER
    GROUP BY 1, 2, 3
),
opening AS (          -- backlog carried in from before the reporting window
    SELECT DISTRIBUTOR_ID, PRODUCT_FAMILY, SUM(VAL) AS OPENING_BACKLOG
    FROM (
        SELECT DISTRIBUTOR_ID, PRODUCT_FAMILY, BOOKINGS AS VAL FROM bookings WHERE WEEK_START < '2024-01-01'
        UNION ALL
        SELECT DISTRIBUTOR_ID, PRODUCT_FAMILY, -SHIPMENTS FROM shipments WHERE WEEK_START < '2024-01-01'
    ) x
    GROUP BY 1, 2
),
flows AS (
    SELECT sp.WEEK_START, sp.WEEK_END, sp.DISTRIBUTOR_ID, sp.PRODUCT_FAMILY,
           COALESCE(b.BOOKINGS, 0)  AS BOOKINGS,
           COALESCE(s.SHIPMENTS, 0) AS SHIPMENTS,
           COALESCE(op.OPENING_BACKLOG, 0) AS OPENING_BACKLOG
    FROM spine sp
    LEFT JOIN bookings  b ON sp.WEEK_START = b.WEEK_START AND sp.DISTRIBUTOR_ID = b.DISTRIBUTOR_ID AND sp.PRODUCT_FAMILY = b.PRODUCT_FAMILY
    LEFT JOIN shipments s ON sp.WEEK_START = s.WEEK_START AND sp.DISTRIBUTOR_ID = s.DISTRIBUTOR_ID AND sp.PRODUCT_FAMILY = s.PRODUCT_FAMILY
    LEFT JOIN opening  op ON sp.DISTRIBUTOR_ID = op.DISTRIBUTOR_ID AND sp.PRODUCT_FAMILY = op.PRODUCT_FAMILY
),
running AS (
    SELECT *,
           OPENING_BACKLOG
             + SUM(BOOKINGS - SHIPMENTS) OVER (PARTITION BY DISTRIBUTOR_ID, PRODUCT_FAMILY
                                               ORDER BY WEEK_START ROWS UNBOUNDED PRECEDING) AS END_BACKLOG
    FROM flows
)
SELECT WEEK_START, WEEK_END, DISTRIBUTOR_ID, PRODUCT_FAMILY,
       END_BACKLOG - BOOKINGS + SHIPMENTS AS BEGIN_BACKLOG,
       BOOKINGS,
       SHIPMENTS,
       END_BACKLOG,
       BOOKINGS - SHIPMENTS               AS NET_CHANGE
FROM running;

-- R2. Delinquent (past-due) backlog trend at each week end
CREATE OR REPLACE VIEW RPT.VW_DELINQUENCY_WEEKLY AS
WITH weeks AS (
    SELECT DISTINCT WEEK_START, DATEADD('day', 6, WEEK_START) AS WEEK_END
    FROM RAW.DIM_DATE
    WHERE WEEK_START BETWEEN '2024-01-01' AND '2026-06-22'
),
past_due_pairs AS (   -- only (line, week) pairs where the line is past due and not fully shipped
    SELECT w.WEEK_START, w.WEEK_END, l.*
    FROM weeks w
    JOIN RPT.VW_ORDER_LINE_STATUS l
      ON l.SCHEDULED_SHIP_DATE < w.WEEK_END
     AND l.ORDER_DATE <= w.WEEK_END
     AND (l.FULL_SHIP_DATE IS NULL OR l.FULL_SHIP_DATE > w.WEEK_END)
),
shipped_by_week AS (
    SELECT pd.WEEK_START, pd.ORDER_ID, pd.LINE_ID, COALESCE(SUM(s.QTY_SHIPPED), 0) AS QTY_SHIPPED
    FROM past_due_pairs pd
    LEFT JOIN RAW.FACT_SHIPMENTS s
      ON pd.ORDER_ID = s.ORDER_ID AND pd.LINE_ID = s.LINE_ID AND s.SHIP_DATE <= pd.WEEK_END
    GROUP BY 1, 2, 3
)
SELECT pd.WEEK_START, pd.DISTRIBUTOR_ID, pd.PRODUCT_FAMILY,
       COUNT(*)                                              AS DELINQUENT_LINES,
       SUM((pd.ORDER_QTY - sb.QTY_SHIPPED) * pd.UNIT_PRICE) AS DELINQUENT_VALUE,
       AVG(DATEDIFF('day', pd.SCHEDULED_SHIP_DATE, pd.WEEK_END)) AS AVG_DAYS_PAST_DUE
FROM past_due_pairs pd
JOIN shipped_by_week sb
  ON pd.WEEK_START = sb.WEEK_START AND pd.ORDER_ID = sb.ORDER_ID AND pd.LINE_ID = sb.LINE_ID
GROUP BY 1, 2, 3;

-- R3. Quarter-to-date billings pace vs prior quarter at the same week
CREATE OR REPLACE VIEW RPT.VW_QTD_BILLINGS_PACE AS
WITH weekly AS (
    SELECT DATE_TRUNC('quarter', INVOICE_DATE) AS QTR,
           FLOOR(DATEDIFF('day', DATE_TRUNC('quarter', INVOICE_DATE), INVOICE_DATE) / 7) + 1 AS WEEK_OF_QTR,
           SUM(AMOUNT) AS BILLINGS
    FROM MART.VW_BILLINGS
    WHERE INVOICE_DATE >= '2024-01-01'
    GROUP BY 1, 2
),
qtd AS (
    SELECT QTR, WEEK_OF_QTR, BILLINGS,
           SUM(BILLINGS) OVER (PARTITION BY QTR ORDER BY WEEK_OF_QTR ROWS UNBOUNDED PRECEDING) AS QTD_BILLINGS,
           SUM(BILLINGS) OVER (PARTITION BY QTR)                                                AS QTR_TOTAL
    FROM weekly
)
SELECT QTR, WEEK_OF_QTR, BILLINGS, QTD_BILLINGS,
       LAG(QTD_BILLINGS) OVER (PARTITION BY WEEK_OF_QTR ORDER BY QTR)            AS PRIOR_QTR_QTD_SAME_WEEK,
       QTD_BILLINGS / NULLIF(LAG(QTD_BILLINGS) OVER (PARTITION BY WEEK_OF_QTR ORDER BY QTR), 0) - 1
                                                                                  AS PACE_VS_PRIOR_QTR,
       QTD_BILLINGS / NULLIF(QTR_TOTAL, 0)                                       AS PCT_OF_QTR_BILLED   -- linearity
FROM qtd;

-- R4. On-time delivery (OTD) by month of commit date
--     Rule: a line is on time if FULLY shipped within 3 days after the
--     scheduled (committed) ship date. Lines past due and still open
--     count as late.
CREATE OR REPLACE VIEW RPT.VW_OTD_MONTHLY AS
SELECT DATE_TRUNC('month', SCHEDULED_SHIP_DATE) AS COMMIT_MONTH,
       DISTRIBUTOR_ID, PRODUCT_FAMILY,
       COUNT(*)                                                                          AS LINES_DUE,
       SUM(IFF(FULL_SHIP_DATE <= DATEADD('day', 3, SCHEDULED_SHIP_DATE), 1, 0))          AS LINES_ON_TIME,
       SUM(IFF(FULL_SHIP_DATE <= DATEADD('day', 3, SCHEDULED_SHIP_DATE), 1, 0)) / COUNT(*) AS OTD_TO_COMMIT,
       SUM(IFF(FULL_SHIP_DATE <= DATEADD('day', 3, REQUEST_DATE), 1, 0)) / COUNT(*)      AS OTD_TO_REQUEST,
       SUM(LINE_VALUE)                                                                   AS VALUE_DUE
FROM RPT.VW_ORDER_LINE_STATUS
WHERE SCHEDULED_SHIP_DATE <= DATEADD('day', -3, '2026-06-28'::DATE)   -- only lines whose window has closed
  AND SCHEDULED_SHIP_DATE >= '2024-01-01'
GROUP BY 1, 2, 3;

-- R5. Monthly distributor scorecard with ranking and rank movement
CREATE OR REPLACE VIEW RPT.VW_DISTRIBUTOR_SCORECARD AS
WITH months AS (
    SELECT DISTINCT DATE_TRUNC('month', DATE) AS MTH
    FROM RAW.DIM_DATE WHERE DATE BETWEEN '2024-01-01' AND '2026-06-28'
),
bill AS (
    SELECT DATE_TRUNC('month', INVOICE_DATE) AS MTH, DISTRIBUTOR_ID, SUM(AMOUNT) AS BILLINGS
    FROM MART.VW_BILLINGS GROUP BY 1, 2
),
otd AS (
    SELECT COMMIT_MONTH AS MTH, DISTRIBUTOR_ID, SUM(LINES_ON_TIME) / SUM(LINES_DUE) AS OTD_TO_COMMIT
    FROM RPT.VW_OTD_MONTHLY GROUP BY 1, 2
),
month_end_week AS (   -- last reporting week that starts in each month
    SELECT DATE_TRUNC('month', WEEK_START) AS MTH, MAX(WEEK_START) AS WEEK_START
    FROM MART.VW_CHANNEL_WEEKLY GROUP BY 1
),
woi AS (
    SELECT m.MTH, c.DISTRIBUTOR_ID, SUM(c.UNITS_ON_HAND) / NULLIF(SUM(c.POS_13WK_AVG), 0) AS WEEKS_OF_INVENTORY
    FROM month_end_week m
    JOIN MART.VW_CHANNEL_WEEKLY c ON c.WEEK_START = m.WEEK_START
    GROUP BY 1, 2
),
delinq AS (
    SELECT m.MTH, d.DISTRIBUTOR_ID, SUM(d.DELINQUENT_VALUE) AS DELINQUENT_VALUE
    FROM month_end_week m
    JOIN RPT.VW_DELINQUENCY_WEEKLY d ON d.WEEK_START = m.WEEK_START
    GROUP BY 1, 2
),
base AS (
    SELECT mo.MTH, dd.DISTRIBUTOR_ID, dd.DISTRIBUTOR_NAME, dd.REGION,
           COALESCE(b.BILLINGS, 0)          AS BILLINGS,
           o.OTD_TO_COMMIT,
           w.WEEKS_OF_INVENTORY,
           COALESCE(dl.DELINQUENT_VALUE, 0) AS DELINQUENT_VALUE
    FROM months mo
    CROSS JOIN RAW.DIM_DISTRIBUTOR dd
    LEFT JOIN bill   b  ON b.MTH = mo.MTH  AND b.DISTRIBUTOR_ID = dd.DISTRIBUTOR_ID
    LEFT JOIN otd    o  ON o.MTH = mo.MTH  AND o.DISTRIBUTOR_ID = dd.DISTRIBUTOR_ID
    LEFT JOIN woi    w  ON w.MTH = mo.MTH  AND w.DISTRIBUTOR_ID = dd.DISTRIBUTOR_ID
    LEFT JOIN delinq dl ON dl.MTH = mo.MTH AND dl.DISTRIBUTOR_ID = dd.DISTRIBUTOR_ID
),
ranked AS (
    SELECT *,
           BILLINGS / NULLIF(SUM(BILLINGS) OVER (PARTITION BY MTH), 0)            AS SHARE_OF_BILLINGS,
           BILLINGS / NULLIF(LAG(BILLINGS) OVER (PARTITION BY DISTRIBUTOR_ID ORDER BY MTH), 0) - 1
                                                                                   AS BILLINGS_MOM_PCT,
           RANK() OVER (PARTITION BY MTH ORDER BY BILLINGS DESC)                   AS BILLINGS_RANK
    FROM base
)
SELECT *,
       LAG(BILLINGS_RANK) OVER (PARTITION BY DISTRIBUTOR_ID ORDER BY MTH) - BILLINGS_RANK AS RANK_CHANGE, -- + = moved up
       CASE WHEN WEEKS_OF_INVENTORY > 14 OR OTD_TO_COMMIT < 0.80 THEN 'Red'
            WHEN WEEKS_OF_INVENTORY > 11 OR OTD_TO_COMMIT < 0.90 THEN 'Amber'
            ELSE 'Green' END AS HEALTH_STATUS
FROM ranked;

-- R6. Tie-out checks (the report pack refuses to publish if any fail)
CREATE OR REPLACE VIEW RPT.VW_REPORT_CHECKS AS
WITH wf_last AS (
    SELECT SUM(END_BACKLOG) AS V FROM RPT.VW_BACKLOG_WATERFALL_WEEKLY
    WHERE WEEK_START = (SELECT MAX(WEEK_START) FROM RPT.VW_BACKLOG_WATERFALL_WEEKLY)
),
cur AS (SELECT SUM(OPEN_VALUE) AS V FROM MART.VW_BACKLOG_CURRENT),
wf_bal AS (   -- each week's begin must equal prior week's end
    SELECT COUNT(*) AS BREAKS FROM (
        SELECT BEGIN_BACKLOG,
               LAG(END_BACKLOG) OVER (PARTITION BY DISTRIBUTOR_ID, PRODUCT_FAMILY ORDER BY WEEK_START) AS PREV_END
        FROM RPT.VW_BACKLOG_WATERFALL_WEEKLY) x
    WHERE PREV_END IS NOT NULL AND ABS(BEGIN_BACKLOG - PREV_END) > 0.01
),
dl_last AS (
    SELECT SUM(DELINQUENT_VALUE) AS V FROM RPT.VW_DELINQUENCY_WEEKLY
    WHERE WEEK_START = (SELECT MAX(WEEK_START) FROM RPT.VW_DELINQUENCY_WEEKLY)
),
dl_cur AS (SELECT SUM(OPEN_VALUE) AS V FROM MART.VW_BACKLOG_CURRENT WHERE IS_DELINQUENT),
bill AS (
    SELECT (SELECT SUM(BILLINGS) FROM RPT.VW_DISTRIBUTOR_SCORECARD) AS SCORECARD_TOTAL,
           (SELECT SUM(AMOUNT) FROM RAW.FACT_BILLING WHERE INVOICE_DATE >= '2024-01-01') AS SOURCE_TOTAL
)
SELECT 'Waterfall end backlog = current backlog view' AS CHECK_NAME,
       (SELECT V FROM wf_last) AS REPORT_VALUE, (SELECT V FROM cur) AS SOURCE_VALUE,
       IFF(ABS((SELECT V FROM wf_last) - (SELECT V FROM cur)) < 1, 'PASS', 'FAIL') AS RESULT
UNION ALL
SELECT 'Waterfall weeks roll forward (begin = prior end)', (SELECT BREAKS FROM wf_bal), 0,
       IFF((SELECT BREAKS FROM wf_bal) = 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'Latest delinquency = current delinquent backlog', (SELECT V FROM dl_last), (SELECT V FROM dl_cur),
       IFF(ABS((SELECT V FROM dl_last) - (SELECT V FROM dl_cur)) < 1, 'PASS', 'FAIL')
UNION ALL
SELECT 'Scorecard billings = source billings', SCORECARD_TOTAL, SOURCE_TOTAL,
       IFF(ABS(SCORECARD_TOTAL - SOURCE_TOTAL) < 1, 'PASS', 'FAIL')
FROM bill;

SELECT * FROM RPT.VW_REPORT_CHECKS;
