-- =====================================================================
-- Prove the fix: compare legacy vs refactored, then explain every gap.
-- =====================================================================
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;

-- A. Totals side by side (Jan-2025 onward)
SELECT 'Legacy' AS VERSION, SUM(BOOKINGS) AS BOOKINGS, SUM(SHIPMENTS) AS SHIPMENTS, SUM(BILLINGS) AS BILLINGS
FROM RPT.VW_MONTHLY_DIST_PERF_LEGACY
UNION ALL
SELECT 'Refactored', SUM(BOOKINGS), SUM(SHIPMENTS), SUM(BILLINGS)
FROM RPT.VW_MONTHLY_DIST_PERF;

-- B. Billings should tie to the source table exactly
SELECT SUM(b.AMOUNT) AS SOURCE_BILLINGS
FROM RAW.FACT_BILLING b
JOIN RAW.FACT_ORDERS o ON b.ORDER_ID = o.ORDER_ID AND b.LINE_ID = o.LINE_ID
WHERE b.INVOICE_DATE >= '2025-01-01'
  AND NOT EXISTS (SELECT 1 FROM RPT.EXCLUDED_PARTS x WHERE x.PART_NUMBER = o.PART_NUMBER);

-- C. Root cause 1 - fan-out: how many order lines have >1 shipment AND >1 invoice?
--    Each of those multiplies rows (shipments x invoices) in the legacy join.
WITH s AS (SELECT ORDER_ID, LINE_ID, COUNT(*) AS N_SHIP FROM RAW.FACT_SHIPMENTS GROUP BY 1, 2),
     b AS (SELECT ORDER_ID, LINE_ID, COUNT(*) AS N_INV  FROM RAW.FACT_BILLING   GROUP BY 1, 2)
SELECT COUNT(*) AS LINES_THAT_FAN_OUT, SUM(N_SHIP * N_INV) AS ROWS_PRODUCED
FROM s JOIN b USING (ORDER_ID, LINE_ID)
WHERE N_SHIP * N_INV > 1;

-- D. Root cause 2 - open orders silently dropped:
--    bookings on lines with NO invoice yet never reach the legacy report
--    (WHERE on b.INVOICE_DATE turns the LEFT JOIN into an INNER JOIN)
SELECT COUNT(*) AS UNBILLED_LINES, SUM(o.ORDER_QTY * o.UNIT_PRICE) AS BOOKINGS_DROPPED
FROM RAW.FACT_ORDERS o
WHERE o.ORDER_DATE >= '2025-01-01'
  AND NOT EXISTS (SELECT 1 FROM RAW.FACT_BILLING b WHERE b.ORDER_ID = o.ORDER_ID AND b.LINE_ID = o.LINE_ID);

-- E. Root cause 3 - NOT IN + NULL: add a blank row to the exclusion list and the legacy view returns nothing
INSERT INTO RPT.EXCLUDED_PARTS VALUES (NULL, 'blank row added by mistake');
SELECT 'Legacy rows' AS T, COUNT(*) AS N FROM RPT.VW_MONTHLY_DIST_PERF_LEGACY
UNION ALL
SELECT 'Refactored rows', COUNT(*) FROM RPT.VW_MONTHLY_DIST_PERF;
DELETE FROM RPT.EXCLUDED_PARTS WHERE PART_NUMBER IS NULL;   -- clean up
