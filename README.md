# Semiconductor Distribution Analytics

I built this portfolio to keep my hands on the kind of work I did in distribution
operations analytics: backlog and billing reporting, channel inventory, distributor
sales data, and the SQL behind all of it.

The data is synthetic. I created by the Python script in your own repo, data/generate_data.py. 
It mimics a chip company selling throughsix distributors, including the messy parts 
(partial shipments, billing errors, distributors resubmitting files), so nothing here uses real company data.
Note: I used AI assistance to build the data generator, then ran, tested, and worked through every project **myself**.

## Projects

| Project | What it covers | Tools |

| [1. Channel health dashboard](project1_channel_health/) | Sell-in vs sell-through, weeks of inventory, backlog | Snowflake, SQL, Power BI |
| [2. Order-to-bill reconciliation](project2_billing_recon/) | Matching orders, shipments and invoices into an exception report | Python |
| [3. Sell-through forecasting](project3_forecasting/) | Backtesting four forecasting methods | Python, statsmodels |
| [4. Weekly reporting pack](project4_reporting_pack/) | Six SQL reports with tie-out checks, automated Excel output | Snowflake, SQL, Python |
| [5. Legacy query refactor](project5_sql_refactor/) | Working out why an old report didn't match Finance | SQL |
| [6. POS ingestion pipeline](project6_pos_ingestion/) | Loading six distributors' JSON sales files into one clean table | Snowflake, SQL |

## A few things the data turned up

1. Two of the six distributors ended up holding about 16 weeks of inventory against a
2. 10-week target, and the projection says it won't clear on its own. The old query in
3. project 5 overstated billings by about 8% because a join multiplied rows. In project 6,
4. one distributor quietly changed its SKU format, which would have dropped those sales
5. from reporting if there hadn't been a check for unmapped SKUs.

## Running it

    pip install -r requirements.txt
    cd data && python generate_data.py && python generate_pos_feeds.py

Each project folder has its own README with the steps. If you don't have Snowflake,
`tools/run_sql_local.py` runs the same SQL locally with DuckDB.

