"""
Project 6 - Multi-source POS ingestion pipeline (local Python version).

  1. EXTRACT   read JSON submissions + CRM accounts + SKU cross-reference
  2. PARSE     flatten submissions into lines; standardize codes, SKUs, dates, numbers
  3. RESOLVE   keep only the latest submission per distributor-week (resubmissions)
  4. VALIDATE  tag each line ACCEPTED or REJECTED with a reason
  5. LOAD      aggregate accepted lines to distributor x part x week (the clean fact)
  6. CHECK     data-quality checks + reconciliation to the true POS (fact_pos.csv)

"""
import glob
import json
import os
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
SRC = os.path.join(DATA, "sources")

# 1. EXTRACT
subs = []
for f in sorted(glob.glob(f"{SRC}/pos_feeds/*.json")):
    for s in json.load(open(f)):
        s["file_name"] = os.path.basename(f)
        subs.append(s)
crm = pd.read_csv(f"{SRC}/crm_accounts.csv")
xref = pd.read_csv(f"{SRC}/sku_xref.csv")

# 2. PARSE 
def parse_week(s):
    for fmt in ("%Y-%m-%d", "%m/%d/%Y"):
        try:
            return pd.to_datetime(s, format=fmt)
        except (ValueError, TypeError):
            pass
    return pd.NaT

hdr = pd.DataFrame([{k: v for k, v in s.items() if k != "lines"} | {"line_count": len(s["lines"])} for s in subs])
hdr = hdr.drop_duplicates("submission_id")                  # same file loaded twice
hdr["dist_code"] = hdr.dist_code.str.strip().str.upper()
hdr["report_week"] = hdr.report_week.map(parse_week)
hdr["submitted_at"] = pd.to_datetime(hdr.submitted_at)

lines = pd.DataFrame([dict(submission_id=s["submission_id"], line_no=i, **l)
                      for s in subs for i, l in enumerate(s["lines"])])
lines["dist_sku"] = lines.sku.astype(str).str.strip().str.upper()
lines["qty"] = pd.to_numeric(lines.qty, errors="coerce")    # "N/A" -> NaN (like TRY_TO_NUMBER)
lines["resale_usd"] = pd.to_numeric(lines.resale_usd, errors="coerce")

# 3. RESOLVE resubmissions: latest submission per distributor-week wins 
hdr = hdr.sort_values("submitted_at")
hdr["is_latest"] = ~hdr.duplicated(["dist_code", "report_week"], keep="last")

# 4. VALIDATE
active = crm[crm.status == "Active"].assign(dist_code=lambda d: d.dist_code.str.strip().str.upper())
xref = xref.assign(dist_sku=xref.dist_sku.str.strip().str.upper(), dist_code=xref.dist_code.str.strip().str.upper())
v = (lines.merge(hdr[["submission_id", "dist_code", "report_week", "is_latest"]], on="submission_id")
          .merge(active[["dist_code", "erp_distributor_id"]], on="dist_code", how="left")
          .merge(xref, on=["dist_code", "dist_sku"], how="left"))
v["dup_rn"] = v.groupby(["submission_id", "dist_sku", "qty", "resale_usd", "ship_to_country"], dropna=False).cumcount() + 1

def status(r):
    if not r.is_latest:                 return "SUPERSEDED"
    if pd.isna(r.erp_distributor_id):   return "REJECTED: unknown distributor"
    if pd.isna(r.report_week):          return "REJECTED: invalid report week"
    if pd.isna(r.qty):                  return "REJECTED: invalid quantity"
    if pd.isna(r.part_number):          return "REJECTED: unmapped SKU"
    if r.dup_rn > 1:                    return "REJECTED: duplicate line"
    return "ACCEPTED"
v["status"] = v.apply(status, axis=1)

# 5. LOAD 
clean = (v[v.status == "ACCEPTED"]
         .groupby(["erp_distributor_id", "part_number", "report_week"], as_index=False)
         .agg(units_sold=("qty", "sum"), resale_value=("resale_usd", "sum"))
         .rename(columns={"erp_distributor_id": "distributor_id", "report_week": "week_start"}))
clean.to_csv(os.path.join(HERE, "fact_pos_clean.csv"), index=False)

# 6. CHECK 
latest = hdr[hdr.is_latest]
line_tot = lines.groupby("submission_id").qty.sum()
ctrl = latest.assign(line_qty=latest.submission_id.map(line_tot)).query("control_total_qty != line_qty")
weeks = pd.date_range("2024-01-01", "2026-06-22", freq="W-MON")
expected = pd.MultiIndex.from_product([active.dist_code, weeks], names=["dist_code", "report_week"]).to_frame(index=False)
missing = expected.merge(latest, on=["dist_code", "report_week"], how="left").query("submission_id.isna()")[["dist_code", "report_week"]]
late = latest[latest.submitted_at > latest.report_week + pd.Timedelta(days=10)]
counts = v.status.value_counts()

checks = pd.DataFrame([
    ("Control total mismatch (latest submissions)", len(ctrl)),
    ("Missing weekly submissions", len(missing)),
    ("Late submissions (>10 days after week)", len(late)),
    ("Lines rejected: unmapped SKU", counts.get("REJECTED: unmapped SKU", 0)),
    ("Lines rejected: invalid quantity", counts.get("REJECTED: invalid quantity", 0)),
    ("Lines rejected: duplicate line", counts.get("REJECTED: duplicate line", 0)),
    ("Lines rejected: unknown distributor", counts.get("REJECTED: unknown distributor", 0)),
    ("Duplicate ACTIVE CRM accounts per distributor", int(active.dist_code.duplicated().sum())),
], columns=["check_name", "failures"])
checks["result"] = checks.failures.map(lambda n: "PASS" if n == 0 else "FAIL")

# reconciliation to the true POS
truth = pd.read_csv(f"{DATA}/fact_pos.csv", parse_dates=["week_start"]).query("units_sold > 0")
rec = truth[["distributor_id", "part_number", "week_start", "units_sold"]].merge(
    clean[["distributor_id", "part_number", "week_start", "units_sold"]],
    on=["distributor_id", "part_number", "week_start"], how="outer", suffixes=("_true", "_pipeline"))
rec["status"] = rec.apply(lambda r: "Missing in pipeline" if pd.isna(r.units_sold_pipeline)
                          else "Extra in pipeline" if pd.isna(r.units_sold_true)
                          else "Match" if r.units_sold_true == r.units_sold_pipeline else "Qty differs", axis=1)
rec_sum = rec.groupby("status", as_index=False).agg(rows=("status", "size"),
                                                   true_units=("units_sold_true", "sum"),
                                                   pipeline_units=("units_sold_pipeline", "sum"))
rec_sum["pct_rows"] = rec_sum.rows / rec_sum.rows.sum()

print("Line status:\n" + counts.to_string())
print("\nData-quality checks:\n" + checks.to_string(index=False))
print("\nReconciliation to true POS:\n" + rec_sum.to_string(index=False))

rejects = v[v.status.str.startswith("REJECTED")][["status", "submission_id", "dist_code", "report_week", "sku",
                                                   "qty", "resale_usd", "ship_to_country"]]
out = os.path.join(HERE, "pos_pipeline_dq_report.xlsx")
with pd.ExcelWriter(out, engine="openpyxl") as xw:
    checks.to_excel(xw, sheet_name="DQ Checks", index=False)
    rec_sum.to_excel(xw, sheet_name="Reconciliation", index=False)
    rejects.to_excel(xw, sheet_name="Rejected Lines", index=False)
    missing.to_excel(xw, sheet_name="Missing Submissions", index=False)
    ctrl[["submission_id", "dist_code", "report_week", "control_total_qty", "line_qty"]].to_excel(
        xw, sheet_name="Control Total Mismatch", index=False)
    late[["submission_id", "dist_code", "report_week", "submitted_at"]].to_excel(xw, sheet_name="Late Submissions", index=False)
    for ws in xw.book.worksheets:
        ws.freeze_panes = "A2"
        for col in ws.columns:
            ws.column_dimensions[col[0].column_letter].width = max(14, min(45, len(str(col[0].value)) + 4))
print(f"\nSaved -> {out}")
