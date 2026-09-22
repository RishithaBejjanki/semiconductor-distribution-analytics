-- Reference table used by the monthly report: end-of-life parts excluded from reporting.
USE WAREHOUSE ANALYTICS_WH;
USE DATABASE CHANNEL_ANALYTICS;
CREATE OR REPLACE TABLE RPT.EXCLUDED_PARTS (PART_NUMBER STRING, REASON STRING);
INSERT INTO RPT.EXCLUDED_PARTS VALUES ('PM-1003', 'End of life'), ('LD-1040', 'End of life');
