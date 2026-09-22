# Project 1: Channel Health Dashboard

**Snowflake · SQL · Power BI · DAX**

## Business problem
A chip manufacturer sells through six distributors. Leadership needs to know every week whether product is **actually selling to end customers** or just **piling up at distributors**. Excess channel inventory means distributors will cut orders later, which hits future revenue.

## What I built
1. **Loaded 8 tables into Snowflake** (`RAW` schema) and validated row counts against source.
2. **Built a reporting layer** (`MART` views): weekly sell-in vs sell-through vs distributor inventory, a 13-week rolling average of sales, weeks of inventory, and current backlog with delinquency aging.
3. **Answered 8 business questions in SQL**, including a forward-looking projection of inventory 13 weeks out and automated data-quality checks.
4. **Built a Power BI dashboard** on a star schema (3 shared dimensions, 4 fact views, marked date table, single-direction relationships, Import mode) with 16 DAX measures, including semi-additive inventory logic.

## Key findings

![Weeks of inventory by distributor]

- **Two of six distributors (Pacific Rim, Summit) hold ~16 weeks of inventory against a 10-week target**, in every product family, while the other four are back near 9 weeks.
- Even counting product already on order, they are **projected to still hold ~15 weeks in 13 weeks' time**. The excess won't clear by itself.

![Sell-in vs sell-through]

- In 2025-Q4 those two distributors **took in 51% more product than they sold**, while the others stayed balanced.

![Book-to-bill]

- **Book-to-bill fell to 0.65 and 0.55** in H2-2025 as distributors stopped ordering to work off stock (bullwhip), then recovered to 1.35 and 1.24 in 2026.
- **74% of past-due backlog is SiC MOSFET**, pointing to a supply constraint rather than a general fulfillment problem.
- All data-quality checks passed: no duplicate orders, orphan shipments, over-shipments, or negative sales.

## Recommendation
Slow shipments to the two overstocked distributors, monitor price-protection and stock-rotation exposure there, and prioritize SiC supply for the oldest past-due orders.

## Files
| File | What it does |

| [`01_snowflake_setup.sql`](01_snowflake_setup.sql) | Warehouse, database, schemas, table definitions, row-count validation |
| [`02_mart_views.sql`](02_mart_views.sql) | Business-ready views Power BI connects to |
| [`03_business_questions.sql`](03_business_questions.sql) | 8 business questions + data-quality checks |
| [`business_question_results.xlsx`](business_question_results.xlsx) | Results of all 8 queries (one tab each) |
| [`powerbi_measures.dax`](powerbi_measures.dax) | All 16 DAX measures |

## Power BI dashboard
Three pages: **Executive Overview** (bookings, billings, book-to-bill, backlog, weeks of inventory), **Channel Health** (sell-in vs sell-through, weeks of inventory by distributor vs target, distributor × family heat map), and **Backlog & Delinquency** (past-due backlog by family and age, top past-due orders).

## How to run
1. In Snowflake, run `01_snowflake_setup.sql`, then load the CSVs from `/data` into the `RAW` tables (Snowsight **Load Data**, or `python tools/load_csvs_to_snowflake.py`).
2. Run `02_mart_views.sql`, then the queries in `03_business_questions.sql` one at a time.
3. Power BI Desktop → Get Data → Snowflake (Import) → load the `MART` views and `RAW.DIM_*` tables → add the measures from `powerbi_measures.dax`.

Without Snowflake: `python tools/run_sql_local.py project1_channel_health/02_mart_views.sql project1_channel_health/03_business_questions.sql`
