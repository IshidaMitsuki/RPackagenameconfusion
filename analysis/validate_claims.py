"""
Paper-oriented validation pipeline for two claims:

Claim A (association):
- Packages with official guidance tend to have higher downloads.

Claim B (causal trend):
- When a non-official same-name GitHub repository appears later,
  downloads tend to increase afterward.

This script builds a monthly package panel and runs:
1) Claim A adjusted association model (controls: package-age FE, calendar-month FE)
2) Claim B event-study DID with package FE and month FE
3) Robustness checks: alternative outcomes, windows, subgroup analyses, placebo timing

Outputs are written to: analysis/paper_validation/
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
import numpy as np
import pandas as pd
from linearmodels.iv.absorbing import AbsorbingLS
from scipy.stats import norm
import platform


# ------------------------------
# Paths
# ------------------------------
PROJECT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_DIR / "data"
OUTPUT_DIR = PROJECT_DIR / "output"
ANALYSIS_DIR = PROJECT_DIR / "analysis" / "paper_validation"
ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)

MONTHLY_CSV = DATA_DIR / "cran_monthly_downloads.csv"
CLASSIFIED_CSV = OUTPUT_DIR / "packages_classified_2x3.csv"


# ------------------------------
# Constants
# ------------------------------
OFFICIAL_YES = "公式へ誘導あり"
OFFICIAL_NO = "公式へ誘導なし"
TIMING_AFTER = "後から同名あり"
TIMING_NONE = "同名なし"

ASSOC_MAX_AGE_MONTHS = 120
MAIN_EVENT_WINDOW = 24


def setup_japanese_font() -> None:
    if platform.system() == "Windows":
        candidates = ["Yu Gothic", "Meiryo", "MS Gothic"]
    elif platform.system() == "Darwin":
        candidates = ["Hiragino Sans", "Hiragino Kaku Gothic ProN"]
    else:
        candidates = ["Noto Sans CJK JP", "IPAGothic"]

    available = {f.name for f in fm.fontManager.ttflist}
    for font in candidates:
        if font in available:
            matplotlib.rcParams["font.family"] = font
            break

    matplotlib.rcParams["axes.unicode_minus"] = False


@dataclass
class EventStudyResult:
    label: str
    outcome: str
    window: int
    n_rows: int
    n_packages: int
    n_treated_packages: int
    n_control_packages: int
    pretrend_stat: float | None
    pretrend_pvalue: float | None
    avg_post_effect: float | None
    avg_post_se: float | None
    avg_post_pvalue: float | None


def month_to_id(dt: pd.Series) -> pd.Series:
    return dt.dt.year * 12 + dt.dt.month


def k_to_col(k: int) -> str:
    return f"event_{'m' + str(abs(k)) if k < 0 else 'p' + str(k)}"


def label_official(v: int) -> str:
    return OFFICIAL_YES if v == 1 else OFFICIAL_NO


def fit_absorbing_ols(
    y: pd.Series,
    exog: pd.DataFrame,
    absorb: pd.DataFrame,
    clusters: pd.Series,
):
    model = AbsorbingLS(y, exog, absorb=absorb)
    return model.fit(cov_type="clustered", clusters=clusters)


def load_panel() -> pd.DataFrame:
    print("[Load] Reading monthly downloads...")
    monthly = pd.read_csv(MONTHLY_CSV, usecols=["Package", "Month", "Downloads"])
    monthly["Month"] = pd.to_datetime(monthly["Month"])

    # Duplicates can appear if the fetch script was rerun; values are typically identical.
    monthly = monthly.drop_duplicates(subset=["Package", "Month"], keep="first")

    print("[Load] Reading classified package metadata...")
    cls = pd.read_csv(
        CLASSIFIED_CSV,
        usecols=[
            "Package",
            "First_Download_Date",
            "official_category",
            "timing_category",
            "first_nonofficial_date",
        ],
    )

    cls["First_Download_Date"] = pd.to_datetime(cls["First_Download_Date"], errors="coerce")
    cls["first_nonofficial_date"] = pd.to_datetime(
        cls["first_nonofficial_date"], errors="coerce", utc=True
    ).dt.tz_localize(None)

    cls["official_guidance"] = (cls["official_category"] == OFFICIAL_YES).astype(int)
    cls["is_treated"] = (cls["timing_category"] == TIMING_AFTER).astype(int)
    cls["is_control"] = (cls["timing_category"] == TIMING_NONE).astype(int)

    cls["first_dl_month"] = cls["First_Download_Date"].dt.to_period("M").dt.to_timestamp()
    cls["treat_month"] = cls["first_nonofficial_date"].dt.to_period("M").dt.to_timestamp()

    panel = monthly.merge(cls, on="Package", how="inner", validate="many_to_one")

    panel["month_id"] = month_to_id(panel["Month"])
    panel["first_dl_month_id"] = month_to_id(panel["first_dl_month"])
    panel["treat_month_id"] = month_to_id(panel["treat_month"])

    panel["age_months"] = panel["month_id"] - panel["first_dl_month_id"]
    panel = panel[panel["age_months"] >= 0].copy()

    panel["event_time"] = panel["month_id"] - panel["treat_month_id"]

    panel["y_asinh"] = np.arcsinh(panel["Downloads"].astype(float))
    panel["y_log1p"] = np.log1p(panel["Downloads"].astype(float))

    print(
        f"[Load] Panel rows={len(panel):,}, packages={panel['Package'].nunique():,}, "
        f"months={panel['Month'].nunique():,}"
    )
    return panel


def run_claim_a_association(panel: pd.DataFrame) -> None:
    print("\n[Claim A] Running adjusted association models...")

    df = panel.copy()
    df = df[df["official_category"].isin([OFFICIAL_YES, OFFICIAL_NO])]
    df = df[(df["age_months"] >= 0) & (df["age_months"] <= ASSOC_MAX_AGE_MONTHS)].copy()

    # Descriptive snapshot
    desc = (
        df.groupby("official_guidance", as_index=False)["Downloads"]
        .agg(["count", "mean", "median"])  # type: ignore[arg-type]
        .reset_index()
    )
    desc["official_label"] = desc["official_guidance"].apply(label_official)
    desc.to_csv(ANALYSIS_DIR / "claim_a_descriptive.csv", index=False, encoding="utf-8-sig")

    # Age-profile medians for visualization
    age_profile = (
        df.groupby(["official_guidance", "age_months"], as_index=False)["Downloads"]
        .median()
        .sort_values(["official_guidance", "age_months"])
    )
    age_profile["official_label"] = age_profile["official_guidance"].apply(label_official)
    age_profile.to_csv(ANALYSIS_DIR / "claim_a_age_profile_median.csv", index=False, encoding="utf-8-sig")

    fig, ax = plt.subplots(figsize=(12, 7))
    for g in [1, 0]:
        sub = age_profile[age_profile["official_guidance"] == g]
        ax.plot(
            sub["age_months"],
            sub["Downloads"],
            label=label_official(g),
            linewidth=2.5,
            alpha=0.9,
        )
    ax.set_xlabel("Package age (months since first download)")
    ax.set_ylabel("Median monthly downloads")
    ax.set_title("Claim A descriptive profile by package age")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(ANALYSIS_DIR / "claim_a_age_profile_median.png", dpi=300)
    plt.close(fig)

    # Adjusted association with high-dimensional FE: age FE + calendar-month FE
    results_rows: list[dict] = []
    for outcome in ["y_asinh", "y_log1p"]:
        y = df[outcome]
        exog = pd.DataFrame({"official_guidance": df["official_guidance"].astype(float)})
        absorb = pd.DataFrame(
            {
                "age_fe": df["age_months"].astype("int32").astype("category"),
                "month_fe": df["Month"].dt.to_period("M").astype(str).astype("category"),
            }
        )
        clusters = df["Package"]

        res = fit_absorbing_ols(y=y, exog=exog, absorb=absorb, clusters=clusters)

        beta = float(res.params["official_guidance"])
        se = float(res.std_errors["official_guidance"])
        pval = float(res.pvalues["official_guidance"])
        ci_low = beta - 1.96 * se
        ci_high = beta + 1.96 * se

        results_rows.append(
            {
                "model": "claim_a_adjusted_association",
                "outcome": outcome,
                "coef_official_guidance": beta,
                "std_error": se,
                "p_value": pval,
                "ci95_low": ci_low,
                "ci95_high": ci_high,
                "n_rows": int(len(df)),
                "n_packages": int(df["Package"].nunique()),
                "age_window_months": f"0-{ASSOC_MAX_AGE_MONTHS}",
            }
        )

    pd.DataFrame(results_rows).to_csv(
        ANALYSIS_DIR / "claim_a_adjusted_models.csv", index=False, encoding="utf-8-sig"
    )
    print("[Claim A] Saved descriptive and adjusted association outputs.")


def build_event_sample(
    panel: pd.DataFrame,
    window: int,
    official_filter: int | None = None,
    placebo_shift_months: int = 0,
) -> pd.DataFrame:
    df = panel.copy()

    treated = (df["is_treated"] == 1) & df["treat_month_id"].notna()
    control = df["is_control"] == 1

    if official_filter is not None:
        treated = treated & (df["official_guidance"] == official_filter)
        control = control & (df["official_guidance"] == official_filter)

    shifted_treat_month_id = df["treat_month_id"] + placebo_shift_months
    event_time = df["month_id"] - shifted_treat_month_id

    treated_in_window = treated & event_time.between(-window, window)
    used_month_ids = pd.Index(df.loc[treated_in_window, "month_id"].unique())

    sample = df[treated_in_window | (control & df["month_id"].isin(used_month_ids))].copy()
    sample["treated_in_sample"] = 0
    sample.loc[treated_in_window.loc[sample.index], "treated_in_sample"] = 1

    sample["event_time_use"] = np.nan
    sample.loc[sample["treated_in_sample"] == 1, "event_time_use"] = event_time.loc[
        sample.index
    ][sample["treated_in_sample"] == 1]
    sample["event_time_use"] = sample["event_time_use"].astype("Int64")

    return sample


def compute_linear_combo(
    params: pd.Series,
    cov: pd.DataFrame,
    terms: Iterable[str],
    weights: np.ndarray,
) -> tuple[float, float, float]:
    cols = list(terms)
    b = params.loc[cols].to_numpy(dtype=float)
    v = cov.loc[cols, cols].to_numpy(dtype=float)
    est = float(weights @ b)
    se = float(np.sqrt(weights @ v @ weights))
    z = est / se if se > 0 else np.nan
    p = float(2 * (1 - norm.cdf(abs(z)))) if np.isfinite(z) else np.nan
    return est, se, p


def run_event_study_model(
    sample: pd.DataFrame,
    outcome: str,
    window: int,
    label: str,
    output_prefix: str,
) -> EventStudyResult:
    ks = [k for k in range(-window, window + 1) if k != -1]

    exog = pd.DataFrame(index=sample.index)
    k_to_colname: dict[int, str] = {}
    for k in ks:
        col = k_to_col(k)
        exog[col] = (
            (sample["treated_in_sample"] == 1) & (sample["event_time_use"] == k)
        ).astype(float)
        k_to_colname[k] = col

    absorb = pd.DataFrame(
        {
            "pkg_fe": sample["Package"].astype("category"),
            "month_fe": sample["Month"].dt.to_period("M").astype(str).astype("category"),
        }
    )

    res = fit_absorbing_ols(
        y=sample[outcome],
        exog=exog,
        absorb=absorb,
        clusters=sample["Package"],
    )

    coef_rows = []
    for k in ks:
        c = k_to_colname[k]
        b = float(res.params[c])
        se = float(res.std_errors[c])
        coef_rows.append(
            {
                "event_time": k,
                "coef": b,
                "std_error": se,
                "p_value": float(res.pvalues[c]),
                "ci95_low": b - 1.96 * se,
                "ci95_high": b + 1.96 * se,
            }
        )

    coef_df = pd.DataFrame(coef_rows).sort_values("event_time")
    coef_df.to_csv(
        ANALYSIS_DIR / f"{output_prefix}_{outcome}_window{window}_coef.csv",
        index=False,
        encoding="utf-8-sig",
    )

    # Pre-trend joint test for k < 0 and k != -1
    pre_cols = [k_to_colname[k] for k in ks if k < 0]
    pretrend_stat = None
    pretrend_p = None
    if pre_cols:
        formula = ", ".join([f"{c} = 0" for c in pre_cols])
        wt = res.wald_test(formula=formula)
        pretrend_stat = float(wt.stat)
        pretrend_p = float(wt.pval)

    # Average post effect across k >= 0
    post_cols = [k_to_colname[k] for k in ks if k >= 0]
    avg_post = None
    avg_post_se = None
    avg_post_p = None
    if post_cols:
        w = np.ones(len(post_cols), dtype=float) / len(post_cols)
        avg_post, avg_post_se, avg_post_p = compute_linear_combo(
            params=res.params,
            cov=res.cov,
            terms=post_cols,
            weights=w,
        )

    # Plot coefficients
    fig, ax = plt.subplots(figsize=(12, 7))
    ax.axhline(0, color="black", linewidth=1)
    ax.axvline(0, color="red", linestyle="--", linewidth=1.5)
    ax.errorbar(
        coef_df["event_time"],
        coef_df["coef"],
        yerr=1.96 * coef_df["std_error"],
        fmt="o-",
        capsize=3,
        linewidth=1.8,
    )
    ax.set_xlabel("Event time (months)")
    ax.set_ylabel(f"Effect on {outcome}")
    ax.set_title(f"Event study DID: {label} ({outcome}, window=+/-{window})")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(
        ANALYSIS_DIR / f"{output_prefix}_{outcome}_window{window}_coef.png",
        dpi=300,
    )
    plt.close(fig)

    n_treated_pkg = int(sample.loc[sample["treated_in_sample"] == 1, "Package"].nunique())
    n_control_pkg = int(sample.loc[sample["is_control"] == 1, "Package"].nunique())

    return EventStudyResult(
        label=label,
        outcome=outcome,
        window=window,
        n_rows=int(len(sample)),
        n_packages=int(sample["Package"].nunique()),
        n_treated_packages=n_treated_pkg,
        n_control_packages=n_control_pkg,
        pretrend_stat=pretrend_stat,
        pretrend_pvalue=pretrend_p,
        avg_post_effect=avg_post,
        avg_post_se=avg_post_se,
        avg_post_pvalue=avg_post_p,
    )


def run_event_study_suite(panel: pd.DataFrame) -> None:
    print("\n[Claim B] Running event-study DID suite...")

    results: list[EventStudyResult] = []

    # Main model (all official statuses pooled): asinh + log1p
    main_sample = build_event_sample(panel, window=MAIN_EVENT_WINDOW)
    results.append(
        run_event_study_model(
            sample=main_sample,
            outcome="y_asinh",
            window=MAIN_EVENT_WINDOW,
            label="Main pooled",
            output_prefix="claim_b_main",
        )
    )
    results.append(
        run_event_study_model(
            sample=main_sample,
            outcome="y_log1p",
            window=MAIN_EVENT_WINDOW,
            label="Main pooled",
            output_prefix="claim_b_main",
        )
    )

    # Window robustness
    for w in [12, 36]:
        sample_w = build_event_sample(panel, window=w)
        results.append(
            run_event_study_model(
                sample=sample_w,
                outcome="y_asinh",
                window=w,
                label=f"Window robustness {w}",
                output_prefix="claim_b_window",
            )
        )

    # Heterogeneity by official guidance
    for off in [1, 0]:
        sample_g = build_event_sample(panel, window=MAIN_EVENT_WINDOW, official_filter=off)
        results.append(
            run_event_study_model(
                sample=sample_g,
                outcome="y_asinh",
                window=MAIN_EVENT_WINDOW,
                label=f"Official subgroup: {label_official(off)}",
                output_prefix=f"claim_b_subgroup_{'official_yes' if off == 1 else 'official_no'}",
            )
        )

    # Placebo timing: pretend treatment happened 12 months earlier
    placebo_sample = build_event_sample(
        panel,
        window=MAIN_EVENT_WINDOW,
        official_filter=None,
        placebo_shift_months=-12,
    )
    results.append(
        run_event_study_model(
            sample=placebo_sample,
            outcome="y_asinh",
            window=MAIN_EVENT_WINDOW,
            label="Placebo (treatment shifted -12 months)",
            output_prefix="claim_b_placebo",
        )
    )

    pd.DataFrame([r.__dict__ for r in results]).to_csv(
        ANALYSIS_DIR / "claim_b_event_study_summary.csv", index=False, encoding="utf-8-sig"
    )
    print("[Claim B] Saved event-study outputs and robustness summary.")


def run_att_interaction(panel: pd.DataFrame) -> None:
    """
    Additional interpretable summary model:
    y ~ treated_post + treated_post x official_guidance + package FE + month FE
    """
    print("\n[Claim B] Running treated-post interaction model...")
    sample = build_event_sample(panel, window=MAIN_EVENT_WINDOW)

    sample["treated_post"] = (
        (sample["treated_in_sample"] == 1) & (sample["event_time_use"] >= 0)
    ).astype(float)
    sample["treated_post_x_official"] = sample["treated_post"] * sample["official_guidance"].astype(float)

    exog = sample[["treated_post", "treated_post_x_official"]].astype(float)
    absorb = pd.DataFrame(
        {
            "pkg_fe": sample["Package"].astype("category"),
            "month_fe": sample["Month"].dt.to_period("M").astype(str).astype("category"),
        }
    )

    rows = []
    for outcome in ["y_asinh", "y_log1p"]:
        res = fit_absorbing_ols(
            y=sample[outcome],
            exog=exog,
            absorb=absorb,
            clusters=sample["Package"],
        )

        b_base = float(res.params["treated_post"])
        se_base = float(res.std_errors["treated_post"])

        b_int = float(res.params["treated_post_x_official"])
        se_int = float(res.std_errors["treated_post_x_official"])

        # Effect in official-guidance group = treated_post + interaction
        w = np.array([1.0, 1.0])
        b_sum, se_sum, p_sum = compute_linear_combo(
            params=res.params,
            cov=res.cov,
            terms=["treated_post", "treated_post_x_official"],
            weights=w,
        )

        rows.extend(
            [
                {
                    "outcome": outcome,
                    "estimand": "post_effect_official_no",
                    "coef": b_base,
                    "std_error": se_base,
                    "p_value": float(res.pvalues["treated_post"]),
                    "ci95_low": b_base - 1.96 * se_base,
                    "ci95_high": b_base + 1.96 * se_base,
                },
                {
                    "outcome": outcome,
                    "estimand": "increment_for_official_yes",
                    "coef": b_int,
                    "std_error": se_int,
                    "p_value": float(res.pvalues["treated_post_x_official"]),
                    "ci95_low": b_int - 1.96 * se_int,
                    "ci95_high": b_int + 1.96 * se_int,
                },
                {
                    "outcome": outcome,
                    "estimand": "post_effect_official_yes_total",
                    "coef": b_sum,
                    "std_error": se_sum,
                    "p_value": p_sum,
                    "ci95_low": b_sum - 1.96 * se_sum,
                    "ci95_high": b_sum + 1.96 * se_sum,
                },
            ]
        )

    pd.DataFrame(rows).to_csv(
        ANALYSIS_DIR / "claim_b_post_interaction_model.csv", index=False, encoding="utf-8-sig"
    )
    print("[Claim B] Saved treated-post interaction results.")


def write_run_note(panel: pd.DataFrame) -> None:
    txt = [
        "Paper validation run metadata",
        "============================",
        f"monthly_csv: {MONTHLY_CSV}",
        f"classified_csv: {CLASSIFIED_CSV}",
        f"rows_used_panel: {len(panel):,}",
        f"packages_used_panel: {panel['Package'].nunique():,}",
        f"month_range: {panel['Month'].min().date()} to {panel['Month'].max().date()}",
        "",
        "Key output files:",
        "- claim_a_descriptive.csv",
        "- claim_a_adjusted_models.csv",
        "- claim_a_age_profile_median.png",
        "- claim_b_event_study_summary.csv",
        "- claim_b_post_interaction_model.csv",
    ]
    (ANALYSIS_DIR / "run_note.txt").write_text("\n".join(txt), encoding="utf-8")


def main() -> None:
    setup_japanese_font()

    print("=" * 80)
    print("Claim Validation Pipeline (paper-oriented)")
    print("=" * 80)

    panel = load_panel()
    run_claim_a_association(panel)
    run_event_study_suite(panel)
    run_att_interaction(panel)
    write_run_note(panel)

    print("\n" + "=" * 80)
    print("Done. Outputs saved to:")
    print(ANALYSIS_DIR)
    print("=" * 80)


if __name__ == "__main__":
    main()
