# Data

Synthetic dataset shared by all six projects. Nothing here comes from a real company.

## How it's generated

`generate_data.py` simulates a chip manufacturer selling 42 parts (6 product families) through 6 fictional distributors, week by week from Jan-2024 to Jun-2026:

- **End demand (POS)** with seasonality, noise, and family trends
- **Distributor ordering** with an order-up-to replenishment policy, which naturally creates bullwhip effects
- **Shipments** with product lead times (8–20 weeks), partial shipments, and random delays
- **Billing** from shipments, with ~2% deliberately injected errors
- **Weekly distributor inventory** snapshots

`generate_pos_feeds.py` then turns the clean POS into messy distributor feeds (JSON), CRM accounts, and a SKU cross-reference for Project 6.

Both use fixed random seeds, so every run produces identical data.

## Built-in business scenarios

1. From Jul-2025, end demand for SiC MOSFET and IGBT Module softens by ~28%.
2. At the same time, distributors D02 and D04 raise their inventory targets (buying ahead), so channel inventory builds while sell-through is flat.
3. From Aug-2025, a SiC supply constraint delays shipments and creates delinquent backlog.
4. About 2% of invoice lines contain errors (Project 2).
5. Distributor feeds contain resubmissions, format differences, a SKU format change, bad values, and missing weeks (Project 6).

## Files

| File | Contents |
|---|---|
| `dim_date.csv`, `dim_product.csv`, `dim_distributor.csv` | Dimensions in star schema |
| `fact_orders.csv`, `fact_shipments.csv`, `fact_billing.csv` | Order-to-cash |
| `fact_pos.csv`, `fact_dist_inventory.csv` | Channel sell-through (true demand) and channel inventory |
| `sources/pos_feeds/*.json` | 64 distributor POS files (796 weekly sales submissions) |
| `sources/crm_accounts.csv`, `sources/sku_xref.csv` | CRM accounts and SKU mapping |
| `_answer_key/` | Lists of the injected errors, used only to measure how well Projects 2 and 6 detect them (not loaded into Snowflake) |
