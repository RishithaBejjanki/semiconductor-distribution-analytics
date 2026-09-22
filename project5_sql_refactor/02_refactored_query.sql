-- =====================================================================
-- REFACTORED: Monthly Distributor Performance
-- Fixes (see CHANGELOG in README.md):
--  1. Each metric aggregated at its own grain BEFORE joining (no fan-out)
--  2. Each metric uses its own date: bookings = order date,
--     shipments = ship date, billings = invoice date
--  3. Date spine: every distributor x month appears, even with zero activity
--  4. NOT EXISTS instead of NOT IN (safe if the exclusion list has a NULL)
--  5. NULLIF guards divide-by-zero; prior-month comparison via LAG
--  6. Reporting window defined once in a params CTE
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;

CREATE OR REPLACE VIEW RPT.VW_MONTHLY_DIST_PERF AS
WITH params AS (
    SELECT '2025-01-01'::DATE AS START_DATE, '2026-06-30'::DATE AS END_DATE
),
in_scope_lines AS (          -- order lines for parts that are not excluded
    SELECT o.*
    FROM RAW.FACT_ORDERS o
    WHERE NOT EXISTS (SELECT 1 FROM RPT.EXCLUDED_PARTS x WHERE x.PART_NUMBER = o.PART_NUMBER)
),
bookings AS (
    SELECT DISTRIBUTOR_ID, DATE_TRUNC('month', ORDER_DATE) AS MTH,
           SUM(ORDER_QTY * UNIT_PRICE) AS BOOKINGS
    FROM in_scope_lines
    GROUP BY 1, 2
),
shipments AS (
    SELECT l.DISTRIBUTOR_ID, DATE_TRUNC('month', s.SHIP_DATE) AS MTH,
           SUM(s.QTY_SHIPPED * l.UNIT_PRICE) AS SHIPMENTS
    FROM RAW.FACT_SHIPMENTS s
    JOIN in_scope_lines l ON s.ORDER_ID = l.ORDER_ID AND s.LINE_ID = l.LINE_ID
    GROUP BY 1, 2
),
billings AS (
    SELECT l.DISTRIBUTOR_ID, DATE_TRUNC('month', b.INVOICE_DATE) AS MTH,
           SUM(b.AMOUNT) AS BILLINGS
    FROM RAW.FACT_BILLING b
    JOIN in_scope_lines l ON b.ORDER_ID = l.ORDER_ID AND b.LINE_ID = l.LINE_ID
    GROUP BY 1, 2
),
spine AS (
    SELECT DISTINCT d.DISTRIBUTOR_ID, d.DISTRIBUTOR_NAME, DATE_TRUNC('month', dt.DATE) AS MTH
    FROM RAW.DIM_DISTRIBUTOR d
    CROSS JOIN RAW.DIM_DATE dt
    CROSS JOIN params p
    WHERE dt.DATE BETWEEN p.START_DATE AND p.END_DATE
),
combined AS (
    SELECT sp.DISTRIBUTOR_NAME, sp.MTH AS REPORT_MONTH,
           COALESCE(bk.BOOKINGS, 0)  AS BOOKINGS,
           COALESCE(sh.SHIPMENTS, 0) AS SHIPMENTS,
           COALESCE(bl.BILLINGS, 0)  AS BILLINGS
    FROM spine sp
    LEFT JOIN bookings  bk ON sp.DISTRIBUTOR_ID = bk.DISTRIBUTOR_ID AND sp.MTH = bk.MTH
    LEFT JOIN shipments sh ON sp.DISTRIBUTOR_ID = sh.DISTRIBUTOR_ID AND sp.MTH = sh.MTH
    LEFT JOIN billings  bl ON sp.DISTRIBUTOR_ID = bl.DISTRIBUTOR_ID AND sp.MTH = bl.MTH
)
SELECT *,
       BOOKINGS / NULLIF(BILLINGS, 0) AS BOOK_TO_BILL,
       LAG(BILLINGS) OVER (PARTITION BY DISTRIBUTOR_NAME ORDER BY REPORT_MONTH) AS PRIOR_MONTH_BILLINGS,
       BILLINGS / NULLIF(LAG(BILLINGS) OVER (PARTITION BY DISTRIBUTOR_NAME ORDER BY REPORT_MONTH), 0) - 1
                                      AS BILLINGS_MOM_PCT
FROM combined;

SELECT * FROM RPT.VW_MONTHLY_DIST_PERF ORDER BY REPORT_MONTH, DISTRIBUTOR_NAME;
