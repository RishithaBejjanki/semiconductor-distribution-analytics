# Data Dictionary: RPT schema

What each report view contains

| View | Grain | Key columns | Purpose |

| VW_ORDER_LINE_STATUS | order line | ORDER_ID, LINE_ID, FULL_SHIP_DATE, QTY_SHIPPED_TO_DATE | Helper: when each line became fully shipped |
| VW_BACKLOG_WATERFALL_WEEKLY | distributor × family × week | BEGIN_BACKLOG, BOOKINGS, SHIPMENTS, END_BACKLOG, NET_CHANGE | Weekly backlog movement |
| VW_DELINQUENCY_WEEKLY | distributor × family × week | DELINQUENT_LINES, DELINQUENT_VALUE, AVG_DAYS_PAST_DUE | Past-due backlog trend |
| VW_QTD_BILLINGS_PACE | quarter × week of quarter | QTD_BILLINGS, PRIOR_QTR_QTD_SAME_WEEK, PACE_VS_PRIOR_QTR, PCT_OF_QTR_BILLED | Billing pace and linearity |
| VW_OTD_MONTHLY | commit month × distributor × family | LINES_DUE, LINES_ON_TIME, OTD_TO_COMMIT, OTD_TO_REQUEST | Delivery performance |
| VW_DISTRIBUTOR_SCORECARD | month × distributor | BILLINGS, SHARE, MOM %, RANK, RANK_CHANGE, OTD, WOI, DELINQUENT_VALUE, HEALTH_STATUS | Distributor health |
| VW_REPORT_CHECKS | one row per check | CHECK_NAME, REPORT_VALUE, SOURCE_VALUE, RESULT | Tie-out gate before publishing |

All money is in USD at order unit price unless stated. Weeks start Monday. 
