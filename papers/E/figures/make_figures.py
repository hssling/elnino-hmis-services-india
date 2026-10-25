"""Paper E figures: Figure_1-5 and Figure_S1 as RGB TIF (LZW, no alpha, one layer, 600 dpi; F23) plus PNG review copies.

    python papers/E/figures/make_figures.py                       (from <repo>; every figure whose inputs exist)
    python papers/E/figures/make_figures.py --figures 1 3 --rename 2=S2 --dpi 600
    python papers/E/figures/make_figures.py --allow-pending    (drafts from results.pending.json; never committed)

prepare step: each figure's data CSV is written to papers/E/figures/data/figure_<name>.csv from its inputs, and the
figure is drawn from that CSV only (the CSVs are the editable figure sources). Figures and their inputs:
  1  national monthly series of the five primary indicators, April 2012-March 2021: data/derived/hmis/hmis_model.csv
     (gated state values, pop_mid, days, oni). Columns: ym, year, month, oni, en_month (ONI >= 0.5), fy2021,
     in_primary, then per indicator <ind>_rate (reported count per 100,000 population per 30 days over the units
     with a value that month: sum(value) / sum(pop_mid * days) * 30 * 1e5; missing is never zero) and <ind>_n_units.
  2  completeness heatmap, unit x month: hmis_model.csv comp_<ind>. Columns: unit_id, unit_name, ym, year, month,
     comp_<ind> for the seven outcomes, comp_min5 (lowest of the five primary indicators; the plotted value), band
     (ge090 / 075_090 / lt075).
  3  forest plot of Models T (all El Nino-phase months and both episodes), S and L: papers/E/results.json keys
     E.t.<I>.{irr_en,irr_en.ep1415,irr_en.ep1819}, E.s.<I>.irr, E.l.<I>.{hw,dry}.irr (the plotted point IS the key
     value, F52) with the 95% bounds from papers/E/output/primary_estimates.csv (spi3_dry: exp(-beta), bounds swapped
     and inverted, as the key). Columns: outcome, panel (T / S / L_hw / L_dry), series (all / ep1415 / ep1819), term,
     key, display, irr, lo, hi, status (ok / not estimable).
  4  distributed-lag curves, lags 0-6: papers/E/output/dlm.csv (04_secondary.R), cross-checked against E.dlm.<I>.lag<k>
     when those keys are final. Columns: outcome, lag, irr, lo, hi, status, key, display, key_status (final/pending).
  5  forecast skill: papers/E/output/forecast_skill.csv; the LOEO pooled differences are the E.fc.<I>.male_diff_c_b /
     male_diff_b_a key values. Columns: outcome, contrast (c_b / b_a), design (loeo / rolling), split_id, diff, key,
     display.
  S1 conditional modes of the unit en_t slope, only for outcomes with E.het.<I>.identifiable TRUE (spec 5.5):
     papers/E/output/het_modes.csv. Columns: outcome, unit_id, unit_name, mode, sd, lo, hi (mode -/+ 1.959964 sd);
     units in unit_id order, never sorted by value.
A figure whose input file is missing (4 and S1 until 04_secondary.R finishes) is skipped with a message. Figures 3,
4, 5 and S1 read papers/E/results.json and stop if it does not exist; --allow-pending (explicit opt-in) reads the
git-ignored results.pending.json instead, with a warning, for drafts that are never committed. A pending key is
refused (an error) for Figures 3, 5 and S1; Figure 4 is drawn from dlm.csv and cross-checked once its keys are final.

Design (F59): black-and-white readable. Series are told apart by marker shape, fill and line style, never by hue
alone; areas by light shading versus hatching; colour is not used. State level only: no district value is read or
written. Each figure can be emitted on its own and renamed (F63: e.g. --rename 2=S2 when Figure 2 moves to the
supplement), which renames its TIF/PNG and its data CSV.
"""
from __future__ import annotations

import io
import json
import math
import textwrap
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib.colors import ListedColormap  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

FIG = Path(__file__).resolve().parent
PAPER = FIG.parent
ROOT = FIG.parents[2]
DATA = FIG / "data"
RESULTS = PAPER / "results.json"
RESULTS_PENDING = PAPER / "results.pending.json"     # git-ignored partial assembly (run_all.R --allow-pending)
OUTPUT = PAPER / "output"
MODEL_CSV = ROOT / "data" / "derived" / "hmis" / "hmis_model.csv"
FRAME = ROOT / "pipeline" / "reference" / "state_frame.csv"

MM = 1 / 25.4
WIDTH_MM = {"single": 84, "double": 174}
plt.rcParams.update({
    "font.family": "sans-serif", "font.sans-serif": ["Arial", "Helvetica", "DejaVu Sans"],
    "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 7.5, "xtick.labelsize": 7, "ytick.labelsize": 7,
    "legend.fontsize": 7, "legend.title_fontsize": 7, "axes.linewidth": 0.6, "xtick.major.width": 0.6,
    "ytick.major.width": 0.6, "xtick.minor.width": 0.5, "ytick.minor.width": 0.5, "lines.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False, "savefig.facecolor": "white",
    "hatch.linewidth": 0.5, "axes.unicode_minus": True, "patch.linewidth": 0.5,
})
# Grayscale ink (F59): every element stays distinct when printed without colour.
INK = "#000000"
DARK = "#404040"
MID = "#808080"
TEXT_GREY = "#595959"     # 7:1 on white
SHADE = "#DCDCDC"         # El Nino months
HATCH_EDGE = "#9A9A9A"    # FY2020-21 hatching
MINUS = "\u2212"
EN_DASH = "\u2013"
NINO = "El Ni\u00f1o"
Z975 = 1.959963984540054

OUTCOMES = ["anc_reg", "penta3", "inst_del", "opd", "diarr_u5", "mcv1", "fic"]        # display order
PRIMARY5 = ["anc_reg", "penta3", "inst_del", "opd", "diarr_u5"]
LABEL = {"diarr_u5": "Diarrhoea, children under 5", "anc_reg": "ANC registration",
         "penta3": "Third DPT-containing dose", "mcv1": "First measles-containing dose", "fic": "Full immunisation",
         "inst_del": "Institutional deliveries", "opd": "Outpatient attendance"}
GROUP = {"anc_reg": "service", "penta3": "service", "inst_del": "service", "opd": "service",
         "diarr_u5": "disease", "mcv1": "secondary", "fic": "secondary"}
EPISODE = {"ep1415": f"{NINO} episode Oct 2014{EN_DASH}Dec 2016",
           "ep1819": f"{NINO} episodes Sep 2018{EN_DASH}Feb 2020"}
# Numbers that may appear in figure text: design labels and scales, never estimates (tests check this).
DESIGN_NUMBERS = {"0", "1", "+1", "3", "5", "6", "30", "100,000", "0.5", "0.75", "0.90", "2012", "2014", "2016",
                  "2017", "2018", "2020", "2021", "34", "19", "95", "21", "16", "17", "18", "20"}

FY2021_START = 2020 * 12 + 3          # ym of April 2020
APR2017 = 2017 * 12 + 3
FIRST_YM = 2012 * 12 + 3
N_MONTHS = 108


# ----------------------------------------------------------------------------- keys
PENDING_WARNING = ("WARNING: --allow-pending reads the git-ignored {name}; figures and data CSVs built from it are "
                    "drafts and must not be committed (rebuild from the final results.json)")


def results_path(path: Path = RESULTS, allow_pending: bool = False, pending: Path = RESULTS_PENDING) -> Path:
    """The results file to read. Default: `path` (papers/E/results.json), an error if it does not exist. Only with
    allow_pending (explicit opt-in, CLI --allow-pending) the partial assembly `pending` (results.pending.json) is read,
    with a printed warning; its pending keys are still refused by final_kv()."""
    if allow_pending:
        pending = Path(pending)
        if not pending.exists():
            raise FileNotFoundError(f"--allow-pending: {pending} not found")
        print(PENDING_WARNING.format(name=pending.name))
        return pending
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"{path} not found: run models/E/run_all.R when every step has finished, or pass "
                                "--allow-pending to draw drafts from results.pending.json (never committed)")
    return path


def load_results(path: Path = RESULTS, allow_pending: bool = False, pending: Path = RESULTS_PENDING) -> dict:
    return json.loads(results_path(path, allow_pending, pending).read_text(encoding="utf-8"))


def kv(res: dict, key: str) -> dict:
    if key not in res:
        raise KeyError(f"results.json has no key {key}")
    return {"key": key, "value": res[key]["value"], "display": res[key]["display"]}


def is_pending(res: dict, key: str) -> bool:
    return str(kv(res, key)["display"]).startswith("pending")


def final_kv(res: dict, key: str) -> dict:
    """A key that must be final: a pending display is an error (the figure would show a placeholder)."""
    if is_pending(res, key):
        raise ValueError(f"{key} is pending ({res[key]['display']}); rerun after Task 11's final assembly")
    return kv(res, key)


def frame() -> pd.DataFrame:
    return pd.read_csv(FRAME)[["unit_id", "unit_name"]]


# ----------------------------------------------------------------------------- data CSVs
def _months(m: pd.DataFrame) -> pd.DataFrame:
    g = m.groupby("ym", as_index=False).agg(year=("year", "first"), month=("month", "first"), oni=("oni", "first"),
                                            in_primary=("in_primary", "max"))
    if len(g) != N_MONTHS or g["ym"].iloc[0] != FIRST_YM:
        raise ValueError(f"hmis_model.csv: expected {N_MONTHS} months from April 2012, got {len(g)}")
    return g


def data_fig1(res: dict | None = None, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    """National monthly rates over the units reporting each month (missing is never zero)."""
    cols = ["unit_id", "ym", "year", "month", "oni", "in_primary", "pop_mid", "days"] + PRIMARY5
    m = pd.read_csv(model_csv, usecols=cols)
    d = _months(m)
    d["en_month"] = d["oni"] >= 0.5
    d["fy2021"] = d["ym"] >= FY2021_START
    for ind in PRIMARY5:
        ok = m[m[ind].notna()]
        g = ok.assign(pd_=ok["pop_mid"] * ok["days"]).groupby("ym").agg(num=(ind, "sum"), den=("pd_", "sum"),
                                                                         n=(ind, "size"))
        g = g.reindex(d["ym"])
        d[f"{ind}_rate"] = (g["num"] / g["den"] * 30 * 1e5).to_numpy()
        d[f"{ind}_n_units"] = g["n"].fillna(0).astype(int).to_numpy()
    return d


def band(x: pd.Series) -> pd.Series:
    return pd.Series(np.select([x >= 0.90, x >= 0.75], ["ge090", "075_090"], "lt075"), index=x.index).where(
        x.notna())


def data_fig2(res: dict | None = None, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    comps = [f"comp_{i}" for i in ["diarr_u5", "anc_reg", "penta3", "mcv1", "fic", "inst_del", "opd"]]
    m = pd.read_csv(model_csv, usecols=["unit_id", "ym", "year", "month"] + comps)
    fr = frame()
    if set(m["unit_id"]) != set(fr["unit_id"]):
        raise ValueError("hmis_model.csv units differ from state_frame.csv")
    m = m.merge(fr, on="unit_id", how="left")
    m["comp_min5"] = m[[f"comp_{i}" for i in PRIMARY5]].min(axis=1, skipna=False)
    m["band"] = band(m["comp_min5"])
    order = {u: i for i, u in enumerate(fr["unit_id"])}
    m = m.sort_values(["unit_id", "ym"], key=lambda s: s.map(order) if s.name == "unit_id" else s)
    return m[["unit_id", "unit_name", "ym", "year", "month"] + comps + ["comp_min5", "band"]].reset_index(drop=True)


FOREST = [  # panel, series, key suffix, model in primary_estimates.csv, term, orientation
    ("T", "all", "t.{o}.irr_en", "T", "en_t", 1),
    ("T", "ep1415", "t.{o}.irr_en.ep1415", "T_ep", "en_ep1415", 1),
    ("T", "ep1819", "t.{o}.irr_en.ep1819", "T_ep", "en_ep1819", 1),
    ("S", "all", "s.{o}.irr", "S", "en_S", 1),
    ("L_hw", "all", "l.{o}.hw.irr", "L", "heatwave_days_l0", 1),
    ("L_dry", "all", "l.{o}.dry.irr", "L", "spi3_dry_l0", -1),     # per unit MORE deficit: exp(-beta), bounds swapped
]


def data_fig3(res: dict, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    """The plotted IRR is the key value (F52); the bounds come from primary_estimates.csv in the key's orientation,
    and the CSV's point estimate must reproduce the key value to 1e-9."""
    pe = pd.read_csv(Path(output_dir) / "primary_estimates.csv")
    rows = []
    for o in OUTCOMES:
        for panel, series, suffix, model, term, sign in FOREST:
            k = final_kv(res, "E." + suffix.format(o=o))
            r = {"outcome": o, "panel": panel, "series": series, "term": term, "key": k["key"],
                 "display": k["display"], "irr": np.nan, "lo": np.nan, "hi": np.nan, "status": "not estimable"}
            if k["value"] is not None:
                e = pe[(pe["outcome"] == o) & (pe["model"] == model) & (pe["term"] == term)]
                if len(e) != 1 or e["status"].iloc[0] != "ok":
                    raise ValueError(f"{k['key']}: no single ok row ({model}, {term}) in primary_estimates.csv")
                e = e.iloc[0]
                irr = math.exp(sign * float(e["est"]))
                if abs(irr - float(k["value"])) > 1e-9:
                    raise ValueError(f"{k['key']}: primary_estimates.csv gives {irr}, the key {k['value']}")
                lo, hi = (float(e["lo"]), float(e["hi"])) if sign == 1 else (1 / float(e["hi"]), 1 / float(e["lo"]))
                r.update(irr=float(k["value"]), lo=lo, hi=hi, status="ok")
            rows.append(r)
    return pd.DataFrame(rows)


def data_fig4(res: dict, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    d = pd.read_csv(Path(output_dir) / "dlm.csv")
    out = []
    for r in d.itertuples():
        key = f"E.dlm.{r.outcome}.lag{int(r.lag)}"
        k = kv(res, key)
        pend = is_pending(res, key)
        irr = float(r.irr) if pd.notna(r.irr) else np.nan
        if not pend:
            v = k["value"]
            if (v is None) != (not np.isfinite(irr)) or (v is not None and abs(irr - float(v)) > 1e-9):
                raise ValueError(f"{key}: dlm.csv gives {irr}, the key {v}")
        out.append({"outcome": r.outcome, "lag": int(r.lag), "irr": irr, "lo": r.lo, "hi": r.hi, "status": r.status,
                    "key": key, "display": k["display"], "key_status": "pending" if pend else "final"})
    out = pd.DataFrame(out)
    if pend_n := int((out["key_status"] == "pending").sum()):
        print(f"Figure 4: {pend_n} E.dlm keys are pending; drawn from dlm.csv without the key cross-check")
    return out


SPLITS = ["pooled", "ep1415", "ep1819", "fy2015", "fy2016", "fy2017", "fy2018", "fy2019"]


def data_fig5(res: dict, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    f = pd.read_csv(Path(output_dir) / "forecast_skill.csv")
    f = f[f["model"].isin(["A", "B", "C"])]
    rows = []
    for o in OUTCOMES:
        for contrast, (m1, m0), suffix in (("c_b", ("C", "B"), "male_diff_c_b"), ("b_a", ("B", "A"), "male_diff_b_a")):
            k = final_kv(res, f"E.fc.{o}.{suffix}")
            for design in ("loeo", "rolling"):
                g = f[(f["outcome"] == o) & (f["design"] == design)].set_index(["model", "split_id"])["male"]
                for s in SPLITS:
                    if (m1, s) not in g.index:
                        continue
                    if design == "rolling" and s == "pooled":
                        continue
                    diff = float(g[(m1, s)] - g[(m0, s)])
                    r = {"outcome": o, "contrast": contrast, "design": design, "split_id": s, "diff": diff,
                         "key": None, "display": None}
                    if design == "loeo" and s == "pooled":
                        if k["value"] is None or abs(diff - float(k["value"])) > 1e-9:
                            raise ValueError(f"{k['key']}: forecast_skill.csv gives {diff}, the key {k['value']}")
                        r.update(diff=float(k["value"]), key=k["key"], display=k["display"])
                    rows.append(r)
    return pd.DataFrame(rows)


def data_figS1(res: dict, output_dir: Path = OUTPUT, model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    """Rows only for outcomes whose E.het.<I>.identifiable value is TRUE (spec 5.5); units in unit_id order."""
    cols = ["outcome", "unit_id", "unit_name", "mode", "sd", "lo", "hi"]
    p = Path(output_dir) / "het_modes.csv"
    try:
        hm = pd.read_csv(p)
    except pd.errors.EmptyDataError:
        hm = pd.DataFrame(columns=["outcome", "unit_id", "mode", "sd", "identifiable"])
    ok = []
    for o in ["diarr_u5", "anc_reg", "penta3", "mcv1", "fic", "inst_del", "opd"]:
        k = final_kv(res, f"E.het.{o}.identifiable")
        if k["value"] is True:
            ok.append(o)
    names = frame().set_index("unit_id")["unit_name"]
    out = []
    for o in ok:
        g = hm[hm["outcome"] == o].copy()
        if g.empty:
            raise ValueError(f"E.het.{o}.identifiable is TRUE but het_modes.csv has no rows for {o}")
        g = g.sort_values("unit_id", kind="stable")         # unit_id order, never by value
        g["unit_name"] = g["unit_id"].map(names)
        g["lo"] = g["mode"] - Z975 * g["sd"]
        g["hi"] = g["mode"] + Z975 * g["sd"]
        out.append(g[cols])
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame(columns=cols)


# ----------------------------------------------------------------------------- drawing helpers
def panel_label(ax, text: str) -> None:
    ax.set_title(text, loc="left", fontweight="bold", fontsize=8)


def _runs(mask) -> list[tuple[int, int]]:
    out, start = [], None
    vals = list(mask) + [False]
    for i, v in enumerate(vals):
        if v and start is None:
            start = i
        if not v and start is not None:
            out.append((start, i - 1))
            start = None
    return out


def _year_ticks(ax, ym: pd.Series) -> None:
    idx = [i for i, v in enumerate(ym) if v % 12 == 0]          # January
    ax.set_xticks(idx)
    ax.set_xticklabels([str(int(ym.iloc[i]) // 12) for i in idx])
    ax.set_xticks([i for i, v in enumerate(ym) if v % 12 == 3], minor=True)   # April (FY start)
    ax.set_xlim(-0.5, len(ym) - 0.5)


# ----------------------------------------------------------------------------- Figure 1
def figure1(csv: Path, width_mm: dict) -> plt.Figure:
    d = pd.read_csv(csv)
    fig, axs = plt.subplots(len(PRIMARY5), 1, sharex=True, layout="constrained",
                            figsize=(width_mm["double"] * MM, 165 * MM))
    x = np.arange(len(d))
    i21 = int(np.flatnonzero(d["fy2021"].astype(bool))[0])
    i17 = int(np.flatnonzero(d["ym"] == APR2017)[0])
    for ax, ind, letter in zip(axs, PRIMARY5, "abcde"):
        for a, b in _runs(d["en_month"].astype(bool)):
            ax.axvspan(a - 0.5, b + 0.5, facecolor=SHADE, edgecolor="none", lw=0, zorder=0, gid="en_shade")
        ax.axvspan(i21 - 0.5, len(d) - 0.5, facecolor="none", edgecolor=HATCH_EDGE, hatch="////", lw=0, zorder=0,
                   gid="fy2021")
        ax.axvline(i17 - 0.5, color=INK, ls=(0, (1, 1.5)), lw=0.8, zorder=1)
        y = d[f"{ind}_rate"].to_numpy()
        ax.plot(x[:i21], y[:i21], color=INK, lw=0.9, zorder=3)
        ax.plot(x[i21 - 1:], y[i21 - 1:], color=DARK, lw=0.9, ls=(0, (3, 1.5)), zorder=3)
        lo = np.nanmin(y)
        hi = np.nanmax(y)
        ax.set_ylim(max(0, lo - 0.08 * (hi - lo)), hi + 0.08 * (hi - lo))
        ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(3))
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, p: f"{v:,.0f}"))
        panel_label(ax, f"({letter}) {LABEL[ind]}")
    _year_ticks(axs[-1], d["ym"])
    axs[-1].set_xlabel("Calendar year (minor ticks: April, the start of each financial year)")
    fig.supylabel("Reported count per 100,000 population per 30 days", fontsize=7.5)
    handles = [Patch(facecolor=SHADE, edgecolor="none", label=f"{NINO} month (ONI \u2265 0.5)"),
               Line2D([], [], color=INK, ls=(0, (1, 1.5)), lw=0.8, label="HMIS format change, April 2017"),
               Patch(facecolor="white", edgecolor=HATCH_EDGE, hatch="////", lw=0,
                     label="FY2020-21 (COVID-19; sensitivity analysis only)"),
               Line2D([], [], color=DARK, ls=(0, (3, 1.5)), lw=0.9, label="Series in FY2020-21")]
    fig.legend(handles=handles, loc="outside upper center", ncol=2, frameon=False)
    return fig


# ----------------------------------------------------------------------------- Figure 2
BAND_CODES = {"ge090": 0, "075_090": 1, "lt075": 2}
BAND_GREYS = ["#F2F2F2", "#8C8C8C", "#1A1A1A"]
BAND_LABELS = ["\u2265 0.90 (enters the models)", f"0.75 to < 0.90", "< 0.75"]


def figure2(csv: Path, width_mm: dict) -> plt.Figure:
    d = pd.read_csv(csv)
    units = list(dict.fromkeys(d["unit_id"]))
    names = d.drop_duplicates("unit_id").set_index("unit_id")["unit_name"]
    yms = sorted(d["ym"].unique())
    grid = (d.assign(code=d["band"].map(BAND_CODES))
            .pivot(index="unit_id", columns="ym", values="code").reindex(index=units, columns=yms))
    fig, ax = plt.subplots(layout="constrained", figsize=(width_mm["double"] * MM, 130 * MM))
    cmap = ListedColormap(BAND_GREYS)
    cmap.set_bad("white")
    ax.imshow(np.ma.masked_invalid(grid.to_numpy(dtype=float)), cmap=cmap, vmin=-0.5, vmax=2.5, aspect="auto",
              interpolation="nearest")
    ax.set_yticks(range(len(units)))
    ax.set_yticklabels([names[u] for u in units])
    ym = pd.Series(yms)
    _year_ticks(ax, ym)
    i17 = int(np.flatnonzero(ym == APR2017)[0])
    i21 = int(np.flatnonzero(ym == FY2021_START)[0])
    ax.axvline(i17 - 0.5, color=INK, ls=(0, (1, 1.5)), lw=0.8)
    ax.axvline(i21 - 0.5, color=INK, ls=(0, (3, 1.5)), lw=0.8)
    for s in ("top", "right"):
        ax.spines[s].set_visible(True)
    ax.set_xlabel("Calendar year (minor ticks: April)")
    bands = [Patch(facecolor=g, edgecolor=INK, lw=0.5, label=lab) for g, lab in zip(BAND_GREYS, BAND_LABELS)]
    lines = [Line2D([], [], color=INK, ls=(0, (1, 1.5)), lw=0.8, label="HMIS format change, April 2017"),
             Line2D([], [], color=INK, ls=(0, (3, 1.5)), lw=0.8, label="Start of FY2020-21 (sensitivity only)")]
    handles = [bands[0], lines[0], bands[1], lines[1], bands[2]]       # column-major: bands on the first row
    if grid.isna().to_numpy().any():
        handles.append(Patch(facecolor="white", edgecolor=INK, lw=0.5, label="No district list"))
    fig.legend(handles=handles, loc="outside upper center", ncol=3, frameon=False,
               title="Lowest reporting completeness of the five primary indicators (valid / listed districts)")
    return fig


# ----------------------------------------------------------------------------- Figure 3
FOREST_PANELS = [("T", "(a) Total\n(Model T)", f"IRR per +1 \u00b0C {NINO}-phase ONI"),
                 ("S", "(b) Differential\n(Model S)", "IRR per +1 \u00b0C per +1 SD\nstate rainfall sensitivity"),
                 ("L_hw", "(c) Heatwave days\n(Model L)", "IRR per additional\nheatwave day"),
                 ("L_dry", "(d) Rainfall deficit\n(Model L)",
                  "IRR per one SPI-3 unit\nmore rainfall deficit")]
SERIES_STYLE = {"all": {"marker": "o", "mfc": INK, "mec": INK, "ms": 4.0, "dy": 0.0},
                "ep1415": {"marker": "s", "mfc": "white", "mec": INK, "ms": 3.6, "dy": 0.27},
                "ep1819": {"marker": "^", "mfc": "white", "mec": INK, "ms": 4.0, "dy": -0.27}}


def _rows_y() -> dict:
    """y of each outcome, top to bottom, with a gap between the service, disease and secondary groups."""
    y, pos, prev = {}, 0.0, None
    for o in OUTCOMES:
        if prev is not None and GROUP[o] != GROUP[prev]:
            pos += 0.6
        y[o] = -pos
        pos += 1.0
        prev = o
    return y


def figure3(csv: Path, width_mm: dict) -> plt.Figure:
    d = pd.read_csv(csv)
    ys = _rows_y()
    fig, axs = plt.subplots(1, 4, sharey=True, layout="constrained", figsize=(width_mm["double"] * MM, 95 * MM),
                            gridspec_kw={"width_ratios": [1.25, 1, 1, 1]})
    for ax, (panel, title, xlabel) in zip(axs, FOREST_PANELS):
        g = d[d["panel"] == panel]
        ax.axvline(1, color=MID, lw=0.6, zorder=0)
        ok = g[g["status"] == "ok"]
        span = max(float((ok["hi"] - 1).abs().max()), float((ok["lo"] - 1).abs().max())) if len(ok) else 0.05
        for r in g.itertuples():
            st = SERIES_STYLE[r.series]
            y = ys[r.outcome] + st["dy"]
            if r.status != "ok":
                ax.text(1, y, "not estimable", ha="center", va="center", fontsize=7, style="italic", color=TEXT_GREY)
                continue
            ax.plot([r.lo, r.hi], [y, y], color=INK, lw=0.8, solid_capstyle="butt", zorder=2)
            ax.plot([r.irr], [y], ls="none", marker=st["marker"], mfc=st["mfc"], mec=st["mec"], ms=st["ms"],
                    mew=0.8, zorder=3)
        ax.set_xlim(1 - 1.12 * span, 1 + 1.12 * span)
        ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(4, steps=[1, 2, 5, 10]))
        ax.xaxis.set_major_formatter(matplotlib.ticker.FormatStrFormatter("%.2f"))
        ax.set_xlabel(xlabel)
        ax.spines["left"].set_visible(panel == "T")
        ax.tick_params(axis="y", length=0)
        panel_label(ax, title)
    axs[0].set_yticks([ys[o] for o in OUTCOMES])
    axs[0].set_yticklabels([LABEL[o] for o in OUTCOMES])
    axs[0].set_ylim(min(ys.values()) - 0.6, 0.6)
    handles = [Line2D([], [], ls="none", marker=SERIES_STYLE["all"]["marker"], mfc=INK, mec=INK, ms=4,
                      label=f"All {NINO}-phase months"),
               Line2D([], [], ls="none", marker="s", mfc="white", mec=INK, ms=3.6, label=EPISODE["ep1415"]),
               Line2D([], [], ls="none", marker="^", mfc="white", mec=INK, ms=4, label=EPISODE["ep1819"])]
    fig.legend(handles=handles, loc="outside upper center", ncol=3, frameon=False,
               title="Panel (a) markers; bars: 95% CI; vertical line: IRR = 1")
    return fig


# ----------------------------------------------------------------------------- Figure 4
def figure4(csv: Path, width_mm: dict) -> plt.Figure:
    d = pd.read_csv(csv)
    order = [o for o in OUTCOMES if o in set(d["outcome"])]
    fig, axs = plt.subplots(2, 4, sharex=True, sharey=True, layout="constrained",
                            figsize=(width_mm["double"] * MM, 95 * MM))
    flat = axs.ravel()
    ok_all = d[d["status"] == "ok"]
    lo, hi = (float(ok_all["lo"].min()), float(ok_all["hi"].max())) if len(ok_all) else (0.95, 1.05)
    for i, (ax, o) in enumerate(zip(flat, order)):
        g = d[d["outcome"] == o].sort_values("lag")
        ax.axhline(1, color=MID, lw=0.6, zorder=0)
        good = g[g["status"] == "ok"]
        if good.empty:
            ax.text(3, 1, "not estimable", ha="center", va="center", fontsize=7, style="italic", color=TEXT_GREY)
        else:
            ax.fill_between(good["lag"], good["lo"], good["hi"], facecolor=SHADE, edgecolor="none", zorder=1)
            ax.plot(good["lag"], good["irr"], color=INK, lw=0.9, marker="o", ms=3, mfc=INK, zorder=3)
        panel_label(ax, "\n".join(textwrap.wrap(f"({'abcdefg'[i]}) {LABEL[o]}", 22)))
    for ax in flat[len(order):]:
        ax.axis("off")
    pad = 0.08 * (hi - lo)
    flat[0].set_ylim(lo - pad, hi + pad)
    flat[0].set_xlim(-0.3, 6.3)
    flat[0].set_xticks(range(7))
    for k, ax in enumerate(flat[:len(order)]):
        if k + 4 >= len(order):                     # lowest drawn panel of its column
            ax.tick_params(axis="x", labelbottom=True)
            ax.set_xlabel("Lag (months)")
    for ax in axs[:, 0]:
        ax.set_ylabel(f"IRR per +1 \u00b0C {NINO}-phase ONI")
    if len(order) < 8:
        leg = flat[len(order)]
        leg.legend(handles=[Line2D([], [], color=INK, lw=0.9, marker="o", ms=3, label="IRR at each lag"),
                            Patch(facecolor=SHADE, edgecolor="none", label="95% CI"),
                            Line2D([], [], color=MID, lw=0.6, label="IRR = 1")], loc="center", frameon=False)
    return fig


# ----------------------------------------------------------------------------- Figure 5
F5_STYLE = {"pooled": {"marker": "D", "mfc": INK, "mec": INK, "ms": 4.2, "dy": 0.0},
            "ep1415": {"marker": "s", "mfc": "white", "mec": INK, "ms": 3.6, "dy": 0.27},
            "ep1819": {"marker": "^", "mfc": "white", "mec": INK, "ms": 4.0, "dy": -0.27},
            "rolling": {"marker": "x", "mfc": INK, "mec": INK, "ms": 3.6}}
ROLL_ORIGINS = ["fy2015", "fy2016", "fy2017", "fy2018", "fy2019"]       # top to bottom within each row
ROLL_LABEL = {o: f"FY{o[2:]}-{int(o[4:]) + 1:02d}" for o in ROLL_ORIGINS}
OUTLIER_SHARE = 0.5      # rolling marks beyond half of the largest rolling-origin |difference| get an origin label


def _diff_axis(ax, vals, xlabel: bool) -> None:
    lo, hi = min(float(np.nanmin(vals)), 0.0), max(float(np.nanmax(vals)), 0.0)
    pad = 0.08 * (hi - lo)
    ax.set_xlim(lo - pad, hi + pad)
    ax.axvline(0, color=MID, lw=0.6, zorder=0)
    ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(6, steps=[1, 2, 5, 10]))
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(
        lambda v, p: (f"{v:+.3f}".rstrip("0").replace("-", MINUS)) if abs(v) > 1e-12 else "0"))
    if xlabel:
        ax.set_xlabel("Difference in mean absolute log error\n(negative: lower error with the added terms)")
    ax.tick_params(axis="y", length=0)


def figure5(csv: Path, width_mm: dict) -> plt.Figure:
    """Rows: leave-one-episode-out (pooled = the key, and the two folds) and rolling origins; columns: C - B and
    B - A. Every panel has its own x-limits, so the rolling-origin extremes do not compress the LOEO panels; rolling
    marks beyond half of the largest rolling-origin |difference| (both contrasts) are labelled with their origin."""
    d = pd.read_csv(csv)
    ys = _rows_y()
    fig, axs = plt.subplots(2, 2, sharey=True, layout="constrained", figsize=(width_mm["double"] * MM, 150 * MM))
    cols = (("c_b", "ENSO terms added (C − B)"), ("b_a", "Local climate added (B − A)"))
    for j, (contrast, what) in enumerate(cols):
        top, bot = axs[0, j], axs[1, j]
        g = d[(d["contrast"] == contrast) & (d["design"] == "loeo")]
        for r in g.itertuples():
            st = F5_STYLE[r.split_id]
            top.plot([r.diff], [ys[r.outcome] + st["dy"]], ls="none", marker=st["marker"], mfc=st["mfc"],
                     mec=st["mec"], ms=st["ms"], mew=0.8, zorder=3, gid=f"loeo_{r.split_id}")
        _diff_axis(top, g["diff"], xlabel=False)
        panel_label(top, f"({'ab'[j]}) {what}:\nleave-one-episode-out")
        g = d[(d["contrast"] == contrast) & (d["design"] == "rolling")]
        big = OUTLIER_SHARE * float(d.loc[d["design"] == "rolling", "diff"].abs().max())
        for r in g.itertuples():
            y = ys[r.outcome] + 0.3 - 0.15 * ROLL_ORIGINS.index(r.split_id)
            bot.plot([r.diff], [y], ls="none", marker="x", mec=INK, ms=3.6, mew=0.8, zorder=3, gid="rolling")
            if abs(r.diff) > big:
                bot.annotate(f"origin {ROLL_LABEL[r.split_id]}", (r.diff, y), xytext=(-5, 0),
                             textcoords="offset points", ha="right", va="center", fontsize=7, color=TEXT_GREY)
        _diff_axis(bot, g["diff"], xlabel=True)
        panel_label(bot, f"({'cd'[j]}) {what}:\nrolling origins")
    for ax in axs[:, 1]:
        ax.spines["left"].set_visible(False)
    axs[0, 0].set_yticks([ys[o] for o in OUTCOMES])
    axs[0, 0].set_yticklabels([LABEL[o] for o in OUTCOMES])
    axs[0, 0].set_ylim(min(ys.values()) - 0.6, 0.6)
    handles = [Line2D([], [], ls="none", marker=F5_STYLE[k]["marker"], mfc=F5_STYLE[k]["mfc"],
                      mec=F5_STYLE[k]["mec"], ms=F5_STYLE[k]["ms"], mew=0.8, label=lab)
               for k, lab in (("pooled", "Leave-one-episode-out, both folds pooled"),
                              ("ep1415", f"Fold: {EPISODE['ep1415']}"),
                              ("ep1819", f"Fold: {EPISODE['ep1819']}"),
                              ("rolling", "Rolling origin, one mark per origin (FY2015-16 at the top)"))]
    fig.legend(handles=handles, loc="outside upper center", ncol=2, frameon=False)
    return fig


# ----------------------------------------------------------------------------- Figure S1
def figureS1(csv: Path, width_mm: dict) -> plt.Figure:
    d = pd.read_csv(csv)
    outs = list(dict.fromkeys(d["outcome"]))
    fig, axs = plt.subplots(1, len(outs), sharey=True, squeeze=False, layout="constrained",
                            figsize=(width_mm["double"] * MM, 130 * MM))
    for i, (ax, o) in enumerate(zip(axs[0], outs)):
        g = d[d["outcome"] == o].reset_index(drop=True)
        y = -np.arange(len(g))
        ax.axvline(0, color=MID, lw=0.6, zorder=0)
        ax.hlines(y, g["lo"], g["hi"], color=INK, lw=0.8, zorder=2)
        ax.plot(g["mode"], y, ls="none", marker="o", ms=3.2, mfc=INK, mec=INK, zorder=3)
        if i == 0:
            ax.set_yticks(y)
            ax.set_yticklabels(list(g["unit_name"]))
        ax.tick_params(axis="y", length=0)
        ax.set_xlabel(f"Unit deviation of the {NINO} slope\n(log IRR per +1 \u00b0C)")
        panel_label(ax, f"({'abcdefg'[i]}) {LABEL[o]}" if len(outs) > 1 else LABEL[o])
    return fig


# ----------------------------------------------------------------------------- registry, save and main
FIGURES = {
    "1": {"build": figure1, "data": data_fig1, "inputs": ["model"], "results": False},
    "2": {"build": figure2, "data": data_fig2, "inputs": ["model"], "results": False},
    "3": {"build": figure3, "data": data_fig3, "inputs": ["primary_estimates.csv"], "results": True},
    "4": {"build": figure4, "data": data_fig4, "inputs": ["dlm.csv"], "results": True},
    "5": {"build": figure5, "data": data_fig5, "inputs": ["forecast_skill.csv"], "results": True},
    "S1": {"build": figureS1, "data": data_figS1, "inputs": ["het_modes.csv"], "results": True},
}


def save(fig, out_dir: Path, name: str, dpi: int) -> list[Path]:
    """Figure_<name>.tif (RGB, LZW, `dpi`, no alpha, one layer) and Figure_<name>.png (half-resolution review copy),
    rendered at the nominal size (no tight bounding box) so the width matches the journal column."""
    from PIL import Image
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=dpi, facecolor="white")
    plt.close(fig)
    buf.seek(0)
    with Image.open(buf) as im:
        rgb = im.convert("RGB")
    tif, png = out_dir / f"Figure_{name}.tif", out_dir / f"Figure_{name}.png"
    rgb.save(tif, format="TIFF", compression="tiff_lzw", dpi=(dpi, dpi))
    w, h = rgb.size
    rgb.resize((max(1, w // 2), max(1, h // 2)), Image.LANCZOS).save(png, format="PNG", dpi=(dpi // 2, dpi // 2))
    print(f"Figure_{name}: {w}x{h} px at {dpi} dpi ({w / dpi * 25.4:.0f} x {h / dpi * 25.4:.0f} mm)")
    return [tif, png]


def main(out_dir: Path = FIG, data_dir: Path = DATA, dpi: int = 600, figures: list[str] | None = None,
         rename: dict | None = None, results: Path = RESULTS, output_dir: Path = OUTPUT,
         model_csv: Path = MODEL_CSV, width_mm: dict | None = None, allow_pending: bool = False,
         pending: Path = RESULTS_PENDING) -> dict:
    """Write each requested figure's data CSV, then draw it. Returns {figure id: [TIF, PNG] or the skip reason}.

    A missing input CSV (dlm.csv, het_modes.csv) skips its figure with a message. A figure that reads keys needs
    papers/E/results.json (FileNotFoundError otherwise); allow_pending reads results.pending.json instead, for
    drafts that are never committed. Figures 1 and 2 read no key."""
    rename = rename or {}
    width_mm = dict(width_mm or WIDTH_MM)
    res = None
    out: dict = {}
    for n in figures or list(FIGURES):
        spec = FIGURES[n]
        name = rename.get(n, n)
        missing = [p for p in ([Path(model_csv)] if spec["inputs"] == ["model"] else
                               [Path(output_dir) / f for f in spec["inputs"]]) if not p.exists()]
        if missing:
            out[n] = f"Figure {n} skipped: input not found: {', '.join(str(p) for p in missing)}"
            print(out[n])
            continue
        if spec["results"] and res is None:
            res = load_results(results, allow_pending, pending)
        d = spec["data"](res, output_dir=Path(output_dir), model_csv=Path(model_csv))
        if d.empty:
            out[n] = f"Figure {n} skipped: no row to draw (no outcome meets the rule)"
            print(out[n])
            continue
        csv = Path(data_dir) / f"figure_{name}.csv"
        csv.parent.mkdir(parents=True, exist_ok=True)
        d.to_csv(csv, index=False, lineterminator="\n", float_format="%.15g")
        out[n] = save(spec["build"](csv, width_mm), Path(out_dir), name, dpi)
    return out


def cli(argv: list[str] | None = None) -> dict:
    import argparse
    ap = argparse.ArgumentParser(description="Draw Paper E Figures 1-5 and S1.")
    ap.add_argument("--out-dir", type=Path, default=FIG)
    ap.add_argument("--data-dir", type=Path, default=DATA)
    ap.add_argument("--dpi", type=int, default=600)
    ap.add_argument("--figures", nargs="*", choices=list(FIGURES), default=None)
    ap.add_argument("--rename", nargs="*", default=[], help="ID=NAME, e.g. 2=S2 when Figure 2 moves to the supplement")
    ap.add_argument("--allow-pending", action="store_true",
                    help="read the git-ignored results.pending.json (drafts only; never commit the outputs)")
    a = ap.parse_args(argv)
    rename = dict(r.split("=", 1) for r in a.rename)
    return main(out_dir=a.out_dir, data_dir=a.data_dir, dpi=a.dpi, figures=a.figures, rename=rename,
                allow_pending=a.allow_pending)


if __name__ == "__main__":
    cli()
