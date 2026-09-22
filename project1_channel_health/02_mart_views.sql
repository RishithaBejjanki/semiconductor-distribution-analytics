-- =====================================================================
-- PROJECT 1 - Business-ready views (the layer Power BI connects to)
-- Builds 4 business-ready views (weekly channel, current backlog, bookings, billings)
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;

-- 1) Weekly channel view: sell-in vs sell-through vs inventory, distributor x part x week
CREATE OR REPLACE VIEW MART.VW_CHANNEL_WEEKLY AS
WITH sell_in AS (
    SELECT o.DISTRIBUTOR_ID, o.PART_NUMBER,
           DATE_TRUNC('week', s.SHIP_DATE)     AS WEEK_START,      -- weeks start Monday
           SUM(s.QTY_SHIPPED)                  AS UNITS_SELL_IN,
           SUM(s.QTY_SHIPPED * o.UNIT_PRICE)   AS SELL_IN_VALUE
    FROM RAW.FACT_SHIPMENTS s
    JOIN RAW.FACT_ORDERS o
      ON s.ORDER_ID = o.ORDER_ID AND s.LINE_ID = o.LINE_ID
    GROUP BY 1, 2, 3
),
base AS (
    SELECT p.DISTRIBUTOR_ID, p.PART_NUMBER, p.WEEK_START,
           p.UNITS_SOLD, p.RESALE_VALUE,
           COALESCE(si.UNITS_SELL_IN, 0)  AS UNITS_SELL_IN,
           COALESCE(si.SELL_IN_VALUE, 0)  AS SELL_IN_VALUE,
           i.UNITS_ON_HAND,
           AVG(p.UNITS_SOLD) OVER (PARTITION BY p.DISTRIBUTOR_ID, p.PART_NUMBER
                                   ORDER BY p.WEEK_START
                                   ROWS BETWEEN 12 PRECEDING AND CURRENT ROW) AS POS_13WK_AVG
    FROM RAW.FACT_POS p
    LEFT JOIN RAW.FACT_DIST_INVENTORY i
      ON p.DISTRIBUTOR_ID = i.DISTRIBUTOR_ID AND p.PART_NUMBER = i.PART_NUMBER
     AND p.WEEK_START = i.SNAPSHOT_WEEK
    LEFT JOIN sell_in si
      ON p.DISTRIBUTOR_ID = si.DISTRIBUTOR_ID AND p.PART_NUMBER = si.PART_NUMBER
     AND p.WEEK_START = si.WEEK_START
)
SELECT *,
       UNITS_ON_HAND / NULLIF(POS_13WK_AVG, 0) AS WEEKS_OF_INVENTORY
FROM base;

-- 2) Current open backlog with delinquency aging (order-line grain)
CREATE OR REPLACE VIEW MART.VW_BACKLOG_CURRENT AS
WITH shipped AS (
    SELECT ORDER_ID, LINE_ID, SUM(QTY_SHIPPED) AS QTY_SHIPPED
    FROM RAW.FACT_SHIPMENTS
    GROUP BY 1, 2
),
lines AS (
    SELECT o.*,
           COALESCE(s.QTY_SHIPPED, 0)                         AS QTY_SHIPPED,
           o.ORDER_QTY - COALESCE(s.QTY_SHIPPED, 0)           AS OPEN_QTY,
           DATEDIFF('day', o.SCHEDULED_SHIP_DATE, '2026-06-28'::DATE) AS DAYS_PAST_DUE
    FROM RAW.FACT_ORDERS o
    LEFT JOIN shipped s
      ON o.ORDER_ID = s.ORDER_ID AND o.LINE_ID = s.LINE_ID
)
SELECT ORDER_ID, LINE_ID, DISTRIBUTOR_ID, PART_NUMBER, ORDER_DATE, SCHEDULED_SHIP_DATE,
       ORDER_QTY, QTY_SHIPPED, OPEN_QTY, UNIT_PRICE,
       OPEN_QTY * UNIT_PRICE AS OPEN_VALUE,
       GREATEST(DAYS_PAST_DUE, 0) AS DAYS_PAST_DUE,
       CASE WHEN DAYS_PAST_DUE <= 0  THEN '0 Not yet due'
            WHEN DAYS_PAST_DUE <= 30 THEN '1 1-30 days'
            WHEN DAYS_PAST_DUE <= 60 THEN '2 31-60 days'
            WHEN DAYS_PAST_DUE <= 90 THEN '3 61-90 days'
            ELSE '4 90+ days' END AS AGING_BUCKET,          -- prefix number = sort order
       IFF(DAYS_PAST_DUE > 0, TRUE, FALSE) AS IS_DELINQUENT
FROM lines
WHERE OPEN_QTY > 0;

-- 3) Bookings and billings at order-line grain for Power BI (dates kept for the Date table)
CREATE OR REPLACE VIEW MART.VW_BOOKINGS AS
SELECT ORDER_ID, LINE_ID, DISTRIBUTOR_ID, PART_NUMBER, ORDER_DATE,
       ORDER_QTY, ORDER_QTY * UNIT_PRICE AS BOOKING_VALUE
FROM RAW.FACT_ORDERS;

CREATE OR REPLACE VIEW MART.VW_BILLINGS AS
SELECT b.INVOICE_ID, b.ORDER_ID, b.LINE_ID, o.DISTRIBUTOR_ID, o.PART_NUMBER,
       b.INVOICE_DATE, b.QTY_BILLED, b.AMOUNT
FROM RAW.FACT_BILLING b
JOIN RAW.FACT_ORDERS o
  ON b.ORDER_ID = o.ORDER_ID AND b.LINE_ID = o.LINE_ID;

-- quick sanity checks
SELECT COUNT(*), SUM(OPEN_VALUE), SUM(IFF(IS_DELINQUENT, OPEN_VALUE, 0)) FROM MART.VW_BACKLOG_CURRENT;
SELECT MAX(WEEK_START), AVG(WEEKS_OF_INVENTORY) FROM MART.VW_CHANNEL_WEEKLY;
