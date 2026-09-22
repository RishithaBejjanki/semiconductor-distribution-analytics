"""" **Script that creates 8 tables**"""

import os
import numpy as np
import pandas as pd

rng = np.random.default_rng(42)
OUT = os.path.dirname(os.path.abspath(__file__))

WEEKS = pd.date_range("2024-01-01", "2026-06-22", freq="W-MON")   # week starts
AS_OF = pd.Timestamp("2026-06-28")                                  # data cut-off
NW = len(WEEKS)

# dimensions
FAMILIES = {
    # family: (price_lo, price_hi, weekly_demand_lo, weekly_demand_hi, lead_time_wks, pack_qty, end_market)
    "Power MOSFET":  (0.35, 1.20, 800, 3000, 10, 500, "Industrial"),
    "IGBT Module":   (18.0, 60.0, 40, 150, 16, 10, "Industrial"),
    "SiC MOSFET":    (6.00, 25.0, 100, 600, 20, 50, "Automotive"),
    "Image Sensor":  (4.00, 15.0, 150, 800, 12, 50, "Automotive"),
    "PMIC":          (1.50, 5.00, 300, 1500, 12, 250, "Consumer"),
    "LDO Regulator": (0.15, 0.60, 1500, 5000, 8, 1000, "Consumer"),
}
prefix = {"Power MOSFET": "PM", "IGBT Module": "IG", "SiC MOSFET": "SC",
          "Image Sensor": "IS", "PMIC": "PW", "LDO Regulator": "LD"}

parts = []
n = 1000
for fam, (plo, phi, dlo, dhi, lt, mpq, mkt) in FAMILIES.items():
    for _ in range(7):
        n += 1
        parts.append(dict(part_number=f"{prefix[fam]}-{n}", product_family=fam, end_market=mkt,
                          list_price=round(rng.uniform(plo, phi), 2),
                          lead_time_weeks=lt, pack_qty=mpq,
                          base_demand=rng.uniform(dlo, dhi)))
dim_product = pd.DataFrame(parts)

dim_distributor = pd.DataFrame([
    ("D01", "Northstar Components",           "Americas", 0.25, 0.02),
    ("D02", "Pacific Rim Electronics",        "APAC",     0.20, 0.03),
    ("D03", "Meridian Supply",                "EMEA",     0.15, 0.02),
    ("D04", "Summit Electronic Distribution", "Americas", 0.15, 0.04),
    ("D05", "Lotus Semiconductor Trading",    "APAC",     0.15, 0.03),
    ("D06", "Alpine Parts Group",             "EMEA",     0.10, 0.01),
], columns=["distributor_id", "distributor_name", "region", "share", "discount"])
dim_distributor["target_woi"] = 10

# demand
t = np.arange(NW)
soft_start = WEEKS.get_indexer([pd.Timestamp("2025-07-07")])[0]

def family_trend(fam):
    tr = np.ones(NW)
    if fam in ("SiC MOSFET", "IGBT Module"):             # demand softens from Jul-2025
        k = np.clip(t - soft_start, 0, None)
        tr = 1 - 0.28 * np.clip(k / 40, 0, 1)
        tr[:soft_start] = 1 + 0.004 * t[:soft_start]      # mild growth before
    elif fam == "PMIC":
        tr = 1 + 0.10 * t / 52
    elif fam == "Image Sensor":
        tr = 1 + 0.03 * np.sin(t / 20)
    return tr

season = 1 + 0.08 * np.sin(2 * np.pi * (t - 10) / 52)   # yearly seasonality

# simulation
order_rows, ship_rows, pos_rows, inv_rows = [], [], [], []
order_seq = {}   # (dist, week) -> order_id
line_seq = {}

sic_con_start = WEEKS.get_indexer([pd.Timestamp("2025-08-04")])[0]
sic_con_end = NW + 30   
def get_order_id(d, week_idx, odate):
    key = (d, week_idx)
    if key not in order_seq:
        order_seq[key] = f"SO{len(order_seq) + 500001}"
        line_seq[key] = 0
    line_seq[key] += 1
    return order_seq[key], line_seq[key]

for _, dist in dim_distributor.iterrows():
    d = dist.distributor_id
    carried = dim_product.sample(frac=0.7, random_state=int(d[1:]) * 7)
    for _, p in carried.iterrows():
        lt, mpq = p.lead_time_weeks, p.pack_qty
        base = p.base_demand * dist.share * 6 * rng.uniform(0.6, 1.4)
        demand = base * family_trend(p.product_family) * season * rng.lognormal(0, 0.15, NW)
        unit_price = round(p.list_price * (1 - dist.discount), 4)

        inv = base * 10
        arrivals = np.zeros(NW + 60)      # qty arriving by week index
        open_orders = []                  # [arrival_week, qty]

        def place(week_idx, qty, odate):
            """create an order line and schedule its shipment(s)"""
            oid, lid = get_order_id(d, week_idx, odate)
            sched_idx = week_idx + lt
            sched_date = (WEEKS[0] + pd.Timedelta(weeks=sched_idx)) + pd.Timedelta(days=2)
            delay = 0
            if p.product_family == "SiC MOSFET" and sic_con_start <= sched_idx <= sic_con_end and rng.random() < 0.55:
                delay = int(rng.integers(4, 16))
            elif rng.random() < 0.06:
                delay = int(rng.integers(1, 4))
            ship_idx = sched_idx + delay
            order_rows.append(dict(order_id=oid, line_id=lid, distributor_id=d, part_number=p.part_number,
                                   order_date=odate.date(),
                                   request_date=(sched_date - pd.Timedelta(weeks=int(rng.integers(0, 3)))).date(),
                                   scheduled_ship_date=sched_date.date(),
                                   order_qty=int(qty), unit_price=unit_price))
            # partial shipments for ~8% of lines
            splits = [qty] if rng.random() > 0.08 else [int(qty * 0.6 // mpq * mpq) or mpq, None]
            if splits[-1] is None:
                splits[-1] = qty - splits[0]
            for i, q in enumerate(splits):
                si = ship_idx + i * int(rng.integers(1, 4))
                sdate = (WEEKS[0] + pd.Timedelta(weeks=si)) + pd.Timedelta(days=int(rng.integers(0, 5)))
                if sdate <= AS_OF and q > 0:
                    ship_rows.append(dict(order_id=oid, line_id=lid, ship_date=sdate.date(), qty_shipped=int(q)))
                if si >= 0:
                    arrivals[max(si, 0)] += q
            return ship_idx

        # pre-history pipeline so the simulation starts in steady state
        for k in range(1, lt + 1):
            w = -k
            odate = WEEKS[0] + pd.Timedelta(weeks=w) + pd.Timedelta(days=int(rng.integers(0, 5)))
            q = max(mpq, round(base / mpq) * mpq)
            place(w, q, odate)

        sold_hist = [base] * 8
        for w in range(NW):
            inv += arrivals[w]
            sold = min(demand[w], inv)
            inv -= sold
            sold_hist.append(sold)
            # POS
            pos_rows.append(dict(distributor_id=d, part_number=p.part_number, week_start=WEEKS[w].date(),
                                 units_sold=int(round(sold)),
                                 resale_value=round(sold * unit_price * rng.uniform(1.12, 1.25), 2)))
            inv_rows.append(dict(distributor_id=d, part_number=p.part_number, snapshot_week=WEEKS[w].date(),
                                 units_on_hand=int(round(inv))))
            # ordering (order-up-to policy)
            target = 10
            if d in ("D02", "D04") and w >= soft_start:
                target = 10 + 8 * min(1, (w - soft_start) / 12)   # buying ahead
            fcst = np.mean(sold_hist[-8:])
            on_order = arrivals[w + 1:].sum()
            need = fcst * (lt + target) - (inv + on_order)
            if need >= mpq * 0.5:
                q = max(mpq, round(need / mpq) * mpq)
                odate = WEEKS[w] + pd.Timedelta(days=int(rng.integers(0, 5)))
                place(w, q, odate)

orders = pd.DataFrame(order_rows)
orders = orders[pd.to_datetime(orders.order_date) <= AS_OF]
shipments = pd.DataFrame(ship_rows)
shipments = shipments.merge(orders[["order_id", "line_id"]], on=["order_id", "line_id"])
shipments.insert(0, "shipment_id", [f"SH{i + 700001}" for i in range(len(shipments))])
pos = pd.DataFrame(pos_rows)
inventory = pd.DataFrame(inv_rows)

# billing + injected errors
bill = shipments.merge(orders[["order_id", "line_id", "unit_price"]], on=["order_id", "line_id"])
bill["invoice_date"] = pd.to_datetime(bill.ship_date) + pd.to_timedelta(rng.integers(0, 3, len(bill)), unit="D")
bill = bill[bill.invoice_date <= AS_OF].copy()
bill["qty_billed"] = bill.qty_shipped
bill["unit_price_billed"] = bill.unit_price
answer = []

idx = bill.index.to_numpy().copy()
rng.shuffle(idx)
n_b = len(idx)
cuts = np.cumsum([int(n_b * 0.006), int(n_b * 0.005), int(n_b * 0.005), int(n_b * 0.003)])
not_billed, qty_mm, price_mm, dupes = np.split(idx[:cuts[-1]], cuts[:-1])

for i in qty_mm:
    bill.at[i, "qty_billed"] = int(bill.at[i, "qty_shipped"] * rng.choice([0.5, 0.8, 1.1, 1.25, 1.5]))
for i in price_mm:
    bill.at[i, "unit_price_billed"] = round(bill.at[i, "unit_price"] * rng.choice([0.85, 0.9, 1.08, 1.15]), 4)
for i, typ in [(i, "shipped_not_billed") for i in not_billed] + [(i, "qty_mismatch") for i in qty_mm] + \
              [(i, "price_mismatch") for i in price_mm] + [(i, "duplicate_invoice") for i in dupes]:
    answer.append(dict(order_id=bill.at[i, "order_id"], line_id=bill.at[i, "line_id"], anomaly_type=typ))

dup_rows = bill.loc[dupes].copy()
dup_rows["invoice_date"] = dup_rows.invoice_date + pd.to_timedelta(rng.integers(3, 20, len(dup_rows)), unit="D")
dup_rows = dup_rows[dup_rows.invoice_date <= AS_OF]
bill = pd.concat([bill.drop(index=not_billed), dup_rows])

# billed but never shipped (open order lines invoiced by mistake)
shipped_keys = set(zip(shipments.order_id, shipments.line_id))
open_lines = orders[[k not in shipped_keys for k in zip(orders.order_id, orders.line_id)]]
open_lines = open_lines[pd.to_datetime(open_lines.order_date) < AS_OF - pd.Timedelta(weeks=6)]
fake = open_lines.sample(n=min(len(open_lines), int(n_b * 0.003)), random_state=1)
fake_bill = pd.DataFrame(dict(order_id=fake.order_id, line_id=fake.line_id,
                              invoice_date=AS_OF - pd.to_timedelta(rng.integers(1, 40, len(fake)), unit="D"),
                              qty_billed=fake.order_qty, unit_price_billed=fake.unit_price))
for _, r in fake.iterrows():
    answer.append(dict(order_id=r.order_id, line_id=r.line_id, anomaly_type="billed_not_shipped"))
bill = pd.concat([bill, fake_bill], ignore_index=True)

bill = bill.sort_values("invoice_date").reset_index(drop=True)
bill["invoice_id"] = [f"INV{i + 900001}" for i in range(len(bill))]
bill["amount"] = (bill.qty_billed * bill.unit_price_billed).round(2)
billing = bill[["invoice_id", "order_id", "line_id", "invoice_date", "qty_billed", "unit_price_billed", "amount"]].copy()
billing["invoice_date"] = billing.invoice_date.dt.date

# date dim
dates = pd.date_range("2023-06-01", "2027-06-30", freq="D")
dim_date = pd.DataFrame(dict(date=dates.date, year=dates.year, quarter=dates.quarter,
                             year_quarter=dates.year.astype(str) + "-Q" + dates.quarter.astype(str),
                             month=dates.month, month_name=dates.strftime("%b"),
                             year_month=dates.strftime("%Y-%m"),
                             week_start=(dates - pd.to_timedelta(dates.weekday, unit="D")).date,
                             day_of_week=dates.strftime("%a")))

# write
dim_product.drop(columns=["base_demand"]).to_csv(f"{OUT}/dim_product.csv", index=False)
dim_distributor.drop(columns=["share", "discount", "target_woi"]).to_csv(f"{OUT}/dim_distributor.csv", index=False)
dim_date.to_csv(f"{OUT}/dim_date.csv", index=False)
orders.sort_values(["order_date", "order_id", "line_id"]).to_csv(f"{OUT}/fact_orders.csv", index=False)
shipments.to_csv(f"{OUT}/fact_shipments.csv", index=False)
billing.to_csv(f"{OUT}/fact_billing.csv", index=False)
pos.to_csv(f"{OUT}/fact_pos.csv", index=False)
inventory.to_csv(f"{OUT}/fact_dist_inventory.csv", index=False)
os.makedirs(f"{OUT}/_answer_key", exist_ok=True)
pd.DataFrame(answer).drop_duplicates().to_csv(f"{OUT}/_answer_key/injected_billing_errors.csv", index=False)

for name, df in [("orders", orders), ("shipments", shipments), ("billing", billing),
                 ("pos", pos), ("inventory", inventory)]:
    print(f"{name:10s} {len(df):>8,} rows")
