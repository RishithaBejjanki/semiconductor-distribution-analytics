""" Script that creates the messy distributor files """

import json
import os
import numpy as np
import pandas as pd

rng = np.random.default_rng(7)
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "sources")
os.makedirs(os.path.join(SRC, "pos_feeds"), exist_ok=True)
for f in os.listdir(os.path.join(SRC, "pos_feeds")):
    os.remove(os.path.join(SRC, "pos_feeds", f))

pos = pd.read_csv(f"{HERE}/fact_pos.csv", parse_dates=["week_start"])
dist = pd.read_csv(f"{HERE}/dim_distributor.csv")
CODE = {"D01": "NSC", "D02": "PRE", "D03": "MRS", "D04": "SED", "D05": "LST", "D06": "APG"}
COUNTRIES = {"Americas": ["US", "MX", "CA"], "APAC": ["CN", "JP", "KR", "TW"], "EMEA": ["DE", "FR", "IT", "NL"]}
region = dict(zip(dist.distributor_id, dist.region))
issues = []

# CRM accounts
crm = [dict(account_id=f"001A{i:05d}XYZ", account_name=n + s, dist_code=CODE[d], erp_distributor_id=d,
            region=region[d], status="Active")
       for i, (d, n, s) in enumerate(zip(dist.distributor_id, dist.distributor_name,
                                         [" Inc.", " Ltd", " GmbH", " LLC", " Pte Ltd", " AG"]), start=1)]
crm.append(dict(account_id="001A00099XYZ", account_name="Pacific Rim Electronics Ltd (legacy)", dist_code="PRE",
                erp_distributor_id="D02", region="APAC", status="Inactive"))
pd.DataFrame(crm).to_csv(f"{SRC}/crm_accounts.csv", index=False)

# SKU cross-reference (canonical form)
pairs = pos[["distributor_id", "part_number"]].drop_duplicates()
xref = pd.DataFrame(dict(dist_code=pairs.distributor_id.map(CODE),
                         dist_sku=pairs.distributor_id.map(CODE) + "-" + pairs.part_number.str.replace("-", ""),
                         part_number=pairs.part_number))
xref.to_csv(f"{SRC}/sku_xref.csv", index=False)

# D01 changes SKU format (adds -TR) for two parts from Apr-2026 -> unmapped
d01_parts = sorted(pairs[pairs.distributor_id == "D01"].part_number)[:2]
TR_START = pd.Timestamp("2026-04-06")
MISSING_WEEKS = {("D06", pd.Timestamp("2026-05-11")), ("D06", pd.Timestamp("2026-05-18"))}

def sku_for(d, part, week):
    s = f"{CODE[d]}-{part.replace('-', '')}"
    if d == "D01" and part in d01_parts and week >= TR_START:
        s += "-TR"
    if d == "D03":
        s = s.lower() + "  "
    return s

def fmt_week(d, week):
    return week.strftime("%m/%d/%Y") if d == "D05" else week.strftime("%Y-%m-%d")

submissions = []
sub_no = 0
pos = pos[pos.units_sold > 0]           # distributors don't report zero-sales lines
for (d, week), grp in pos.groupby(["distributor_id", "week_start"]):
    if (d, week) in MISSING_WEEKS:
        for _, r in grp.iterrows():
            issues.append(dict(issue="missing_submission", distributor_id=d, part_number=r.part_number, week_start=week.date()))
        continue
    lines = []
    for _, r in grp.iterrows():
        n = int(rng.integers(1, 4)) if r.units_sold >= 3 else 1
        cuts = np.sort(rng.choice(np.arange(1, r.units_sold), size=n - 1, replace=False)) if n > 1 else []
        qtys = np.diff(np.concatenate([[0], cuts, [r.units_sold]])).astype(int)
        ctry = rng.choice(COUNTRIES[region[d]], size=n, replace=False)
        for q, c in zip(qtys, ctry):
            lines.append(dict(sku=sku_for(d, r.part_number, week), qty=int(q),
                              resale_usd=round(r.resale_value * q / r.units_sold, 2), ship_to_country=str(c),
                              _part=r.part_number))
        if d == "D01" and r.part_number in d01_parts and week >= TR_START:
            issues.append(dict(issue="unmapped_sku", distributor_id=d, part_number=r.part_number, week_start=week.date()))
    control = sum(l["qty"] for l in lines)
    submitted = week + pd.Timedelta(days=7) + pd.Timedelta(hours=int(rng.integers(1, 72)))

    if rng.random() < 0.03:             # original had errors -> corrected resubmission later
        bad = [dict(l) for l in lines]
        for i in rng.choice(len(bad), size=min(3, len(bad)), replace=False):
            bad[i]["qty"] = int(round(bad[i]["qty"] * rng.choice([0.7, 1.3, 1.5]))) or 1
        sub_no += 1
        submissions.append(dict(submission_id=f"SUB{sub_no:06d}", dist_code=CODE[d], report_week=fmt_week(d, week),
                                submitted_at=submitted.isoformat(), control_total_qty=sum(l["qty"] for l in bad),
                                lines=bad))
        submitted = submitted + pd.Timedelta(days=int(rng.integers(14, 30)))
        issues.append(dict(issue="resubmitted_week", distributor_id=d, part_number=None, week_start=week.date()))

    for l in lines:                      # corrupt quantities -> "N/A"
        if rng.random() < 0.0004:
            l["qty"] = "N/A"
            issues.append(dict(issue="invalid_qty", distributor_id=d, part_number=l["_part"], week_start=week.date()))
    dups = [dict(l) for l in lines if rng.random() < 0.003]
    for l in dups:
        issues.append(dict(issue="duplicate_line", distributor_id=d, part_number=l["_part"], week_start=week.date()))
    lines += dups
    if d == "D02" and week == pd.Timestamp("2025-03-10"):
        lines.append(dict(sku="TEST-SKU-001", qty=1, resale_usd=0.0, ship_to_country="CN", _part=None))
        issues.append(dict(issue="test_row", distributor_id=d, part_number=None, week_start=week.date()))
    sub_no += 1
    submissions.append(dict(submission_id=f"SUB{sub_no:06d}", dist_code=CODE[d], report_week=fmt_week(d, week),
                            submitted_at=submitted.isoformat(), control_total_qty=control, lines=lines))

files = {}
for s in submissions:
    for l in s["lines"]:
        l.pop("_part", None)
    q = pd.Timestamp(s["submitted_at"]).to_period("Q")
    files.setdefault((s["dist_code"], str(q)), []).append(s)
for (code, q), subs in files.items():
    with open(os.path.join(SRC, "pos_feeds", f"pos_{code}_{q}.json"), "w") as fh:
        json.dump(subs, fh)

os.makedirs(f"{HERE}/_answer_key", exist_ok=True)
pd.DataFrame(issues).to_csv(f"{HERE}/_answer_key/pos_feed_issues.csv", index=False)
print(f"{len(submissions):,} submissions in {len(files)} JSON files; "
      f"{sum(len(s['lines']) for s in submissions):,} lines")
print(pd.DataFrame(issues).issue.value_counts().to_string())
