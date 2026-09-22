"""
Project 2 - Automated order-to-bill reconciliation.

Python script that matches orders, shipments, and invoices.

"""
import os
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
AS_OF = pd.Timestamp("2026-06-28")
BILLING_LAG_DAYS = 7          # shipments younger than this are not expected to be billed yet
PRICE_TOLERANCE = 0.005       # 0.5% rounding tolerance

orders = pd.read_csv(f"{DATA}/fact_orders.csv")
ships = pd.read_csv(f"{DATA}/fact_shipments.csv", parse_dates=["ship_date"])
bills = pd.read_csv(f"{DATA}/fact_billing.csv", parse_dates=["invoice_date"])
dist = pd.read_csv(f"{DATA}/dim_distributor.csv")
prod = pd.read_csv(f"{DATA}/dim_product.csv")
KEY = ["order_id", "line_id"]

# 1. data-quality checks before reconciling (row counts, nulls, orphans)
dq = pd.DataFrame([
    ("orders", len(orders), int(orders.duplicated(KEY).sum()), int(orders.isna().any(axis=1).sum())),
    ("shipments", len(ships), int(ships.duplicated("shipment_id").sum()), int(ships.isna().any(axis=1).sum())),
    ("billing", len(bills), int(bills.duplicated("invoice_id").sum()), int(bills.isna().any(axis=1).sum())),
], columns=["table", "rows", "duplicate_keys", "rows_with_nulls"])

# 2. aggregate each side to order-line grain
s = (ships[ships.ship_date <= AS_OF - pd.Timedelta(days=BILLING_LAG_DAYS)]
     .groupby(KEY, as_index=False).agg(qty_shipped=("qty_shipped", "sum"), last_ship=("ship_date", "max")))
b = bills.groupby(KEY, as_index=False).agg(qty_billed=("qty_billed", "sum"), amount_billed=("amount", "sum"),
                                           n_invoices=("invoice_id", "nunique"),
                                           max_bill_price=("unit_price_billed", "max"),
                                           min_bill_price=("unit_price_billed", "min"))
dup_flag = (bills.groupby(KEY + ["qty_billed", "amount"]).invoice_id.nunique()
            .reset_index(name="n").query("n > 1")[KEY].drop_duplicates().assign(has_duplicate=True))

# 3. full outer join so records missing on EITHER side surface
r = (s.merge(b, on=KEY, how="outer", indicator=True)
      .merge(orders[KEY + ["distributor_id", "part_number", "unit_price"]], on=KEY, how="left")
      .merge(dup_flag, on=KEY, how="left"))
# invoices on lines whose shipment is still inside the billing lag are not errors
recent = ships[ships.ship_date > AS_OF - pd.Timedelta(days=BILLING_LAG_DAYS)][KEY].drop_duplicates()
r = r.merge(recent.assign(recent_ship=True), on=KEY, how="left")
r["has_duplicate"] = r.has_duplicate.fillna(False).astype(bool)
r["recent_ship"] = r.recent_ship.fillna(False).astype(bool)
r[["qty_shipped", "qty_billed", "amount_billed"]] = r[["qty_shipped", "qty_billed", "amount_billed"]].fillna(0)

def classify(x):
    if x._merge == "right_only" and not x.recent_ship:
        return "billed_not_shipped"
    if x._merge == "left_only":
        return "shipped_not_billed"
    if x._merge == "both":
        if x.has_duplicate and x.qty_billed > x.qty_shipped:
            return "duplicate_invoice"
        if x.qty_billed != x.qty_shipped:
            return "qty_mismatch"
        if (abs(x.max_bill_price - x.unit_price) > PRICE_TOLERANCE * x.unit_price or
                abs(x.min_bill_price - x.unit_price) > PRICE_TOLERANCE * x.unit_price):
            return "price_mismatch"
    return None

r["issue"] = r.apply(classify, axis=1)
exc = r[r.issue.notna()].copy()

# 4. dollar impact: what SHOULD have been billed vs what WAS billed
exc["expected_amount"] = exc.qty_shipped * exc.unit_price
exc["variance"] = (exc.amount_billed - exc.expected_amount).round(2)
exc["abs_variance"] = exc.variance.abs()
exc["direction"] = exc.variance.map(lambda v: "Over-billed (customer dispute risk)" if v > 0
                                    else "Under-billed (revenue leakage)")
exc = (exc.merge(dist[["distributor_id", "distributor_name", "region"]], on="distributor_id", how="left")
          .merge(prod[["part_number", "product_family"]], on="part_number", how="left"))
exc["owner"] = exc.issue.map({"billed_not_shipped": "Billing Ops", "shipped_not_billed": "Billing Ops",
                              "duplicate_invoice": "Billing Ops", "qty_mismatch": "Logistics / Billing",
                              "price_mismatch": "Pricing / Contracts"})
cols = ["issue", "owner", "order_id", "line_id", "distributor_name", "region", "part_number", "product_family",
        "qty_shipped", "qty_billed", "unit_price", "min_bill_price", "max_bill_price", "n_invoices",
        "expected_amount", "amount_billed", "variance", "direction"]
exc = exc.sort_values("abs_variance", ascending=False)[cols]

summary = (exc.assign(abs_variance=exc.variance.abs())
              .groupby(["issue", "owner"], as_index=False)
              .agg(lines=("order_id", "size"), net_variance=("variance", "sum"),
                   gross_impact=("abs_variance", "sum"))
              .sort_values("gross_impact", ascending=False))

# 5. (portfolio only) score against the injected answer key
key_path = f"{DATA}/_answer_key/injected_billing_errors.csv"
if os.path.exists(key_path):
    truth = pd.read_csv(key_path)
    found = set(zip(exc.order_id, exc.line_id))
    real = set(zip(truth.order_id, truth.line_id))
    tp = len(found & real)
    print(f"Detection: recall {tp / len(real):.1%} | precision {tp / len(found):.1%} "
          f"({tp} of {len(real)} injected errors found, {len(found)} lines flagged)")

# 6. write the exception report
out = os.path.join(HERE, "billing_exceptions.xlsx")
with pd.ExcelWriter(out, engine="openpyxl") as xw:
    summary.to_excel(xw, sheet_name="Summary", index=False)
    exc.to_excel(xw, sheet_name="Exceptions", index=False)
    dq.to_excel(xw, sheet_name="Data Quality", index=False)
    for ws in xw.book.worksheets:
        ws.freeze_panes = "A2"
        for col in ws.columns:
            ws.column_dimensions[col[0].column_letter].width = max(12, min(40, len(str(col[0].value)) + 4))
print(summary.to_string(index=False))
print(f"\nGross $ impact flagged: ${summary.gross_impact.sum():,.0f}  ->  {out}")
