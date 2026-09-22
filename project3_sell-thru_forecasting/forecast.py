"""
Project 3 - Sell-through (POS) demand forecasting with honest backtesting.

Backtest, Model selection, forward forecast

"""
import os
import warnings
import numpy as np
import pandas as pd
from statsmodels.tsa.holtwinters import ExponentialSmoothing

warnings.filterwarnings("ignore")
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
H = 13                 # forecast horizon (one quarter)
N_ORIGINS = 6          # backtest cut-off points, 4 weeks apart

pos = pd.read_csv(f"{DATA}/fact_pos.csv", parse_dates=["week_start"])
prod = pd.read_csv(f"{DATA}/dim_product.csv")
# forecast at PART level (summed across distributors) - the level planners act on
weekly = pos.groupby(["part_number", "week_start"]).units_sold.sum().unstack(0).sort_index()
family_of = prod.set_index("part_number").product_family


def fc_naive(y, h):        return np.repeat(y.iloc[-1], h)
def fc_ma8(y, h):          return np.repeat(y.iloc[-8:].mean(), h)
def fc_seasonal(y, h):     return y.iloc[-52:-52 + h].to_numpy() if len(y) >= 52 + h else fc_ma8(y, h)
def fc_holt(y, h):
    m = ExponentialSmoothing(y.to_numpy(), trend="add", damped_trend=True).fit()
    return np.clip(m.forecast(h), 0, None)

MODELS = {"naive_last": fc_naive, "moving_avg_8": fc_ma8, "seasonal_naive": fc_seasonal, "holt_damped": fc_holt}

def wmape(actual, fcst):   return np.abs(actual - fcst).sum() / actual.sum()
def bias(actual, fcst):    return (fcst - actual).sum() / actual.sum()     # + = over-forecast

rows = []
n = len(weekly)
origins = [n - H - 4 * k for k in range(N_ORIGINS)]
for part in weekly.columns:
    y = weekly[part]
    fam = family_of[part]
    for o in origins:
        train, test = y.iloc[:o], y.iloc[o:o + H].to_numpy()
        for name, f in MODELS.items():
            fc = f(train, H)
            rows.append(dict(product_family=fam, part_number=part, origin=y.index[o].date(), model=name,
                             actual=test.sum(), abs_err=np.abs(test - fc).sum(), signed_err=(fc - test).sum()))

bt = pd.DataFrame(rows)
score = (bt.groupby(["product_family", "model"], as_index=False)[["actual", "abs_err", "signed_err"]].sum()
           .assign(wmape=lambda d: d.abs_err / d.actual, bias=lambda d: d.signed_err / d.actual))
pivot = score.pivot(index="product_family", columns="model", values="wmape")
best = score.loc[score.groupby("product_family").wmape.idxmin(), ["product_family", "model", "wmape", "bias"]]
best = best.merge(pivot["naive_last"].rename("baseline_wmape"), on="product_family")
best["improvement_vs_baseline_pts"] = (best.baseline_wmape - best.wmape) * 100

# forward forecast: every part uses its family's winning model
future_idx = pd.date_range(weekly.index[-1] + pd.Timedelta(weeks=1), periods=H, freq="W-MON")
win = best.set_index("product_family").model
fwd = pd.DataFrame({p: MODELS[win[family_of[p]]](weekly[p], H) for p in weekly.columns}, index=future_idx).round(0)
fwd.index.name = "week_start"

print("Backtest WMAPE by model (lower is better):")
print((pivot * 100).round(1).to_string())
print("\nWinner per family:")
print(best.assign(wmape=lambda d: (d.wmape * 100).round(1), bias=lambda d: (d.bias * 100).round(1),
                  baseline_wmape=lambda d: (d.baseline_wmape * 100).round(1),
                  improvement_vs_baseline_pts=lambda d: d.improvement_vs_baseline_pts.round(1)).to_string(index=False))

sel = bt.merge(best[["product_family", "model"]], on=["product_family", "model"])
base = bt[bt.model == "naive_last"]
print(f"\nOverall WMAPE: naive baseline {base.abs_err.sum() / base.actual.sum():.1%} "
      f"-> best model per family {sel.abs_err.sum() / sel.actual.sum():.1%}")

out = os.path.join(HERE, "forecast_results.xlsx")
with pd.ExcelWriter(out, engine="openpyxl") as xw:
    best.to_excel(xw, sheet_name="Model Selection", index=False)
    (pivot * 100).round(2).to_excel(xw, sheet_name="WMAPE by Model")
    fwd.to_excel(xw, sheet_name="13wk Forecast")
    weekly.to_excel(xw, sheet_name="History")
    bt.to_excel(xw, sheet_name="Backtest Detail", index=False)
print(f"\nSaved -> {out}")
