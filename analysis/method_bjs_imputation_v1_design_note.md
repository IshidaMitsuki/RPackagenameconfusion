# BJS imputation v1 design note

This note documents the paper-facing specification implemented in
`analysis/script/method_bjs_imputation_v1.R`.

## Reference Papers

The current method comparison is based on two newer references:

- Borusyak, Jaravel, and Spiess (2024), "Revisiting Event Study Designs:
  Robust and Efficient Estimation"
- Clarke et al. (2024), "On Synthetic Difference-in-Differences and Related
  Estimation Methods in Stata"

## Target

The event remains the first appearance of a same-name non-official GitHub
repository. The outcome is `log_dl`.

The main BJS estimand is the average post-event imputation residual over
event time `e = 0..60`. The script reports two aggregations:

- `dynamic_att_event_equal_0_60`: equal weight across event-time cells.
- `dynamic_att_obs_weighted_0_60`: weight event-time cells by treated
  observations.

Balanced summaries are also reported for horizons `12, 24, 36, 48`.

## Untreated outcome model

The untreated potential outcome model is

```text
log_dl_it = alpha_i + lambda_t + error_it
```

estimated only on untreated observations:

```text
G == 0, or period < G
```

The imputed treatment effect for treated observations is

```text
tau_hat_it = log_dl_it - y0_hat_it
```

This follows the imputation representation in Borusyak, Jaravel, and Spiess
(2024), with unrestricted treatment-effect heterogeneity.

## Samples

The script constructs:

- `overall`
- `official_before_yes`
- `official_before_no`
- `gte13`
- `glt12`
- `gte12`
- `preobs_ge12`
- `official_before_yes_gte13`
- `official_before_no_gte13`
- `official_before_yes_preobs_ge12`
- `official_before_no_preobs_ge12`

These mirror the main C&S analysis, official-before subgroups, and pre-period
support sensitivity checks.

## BJS pre-trend/no-anticipation test

The script now implements a BJS Test 1 style diagnostic. It estimates, using
untreated observations only:

```text
log_dl_it = alpha_i + lambda_t + gamma_1 lead_1_it + ... + gamma_k lead_k_it + error_it
```

where `lead_j` indicates observations `j` periods before treatment. The default
is `k = 12`.

Outputs:

- `bjs_pretrend_test_summary.csv`
- `bjs_pretrend_test_coefficients.csv`

The Wald test is cluster-robust by package. This is the paper-aligned
pre-trend/no-anticipation diagnostic. The older
`bjs_pre_event_diagnostics.csv` is only an imputation-residual diagnostic and
should not be described as the formal BJS pre-trend test.

## Inference

Naive standard errors are kept only for descriptive diagnostics and quick
checks. They are not the paper-facing BJS inference. They are explicitly named:

- `se_naive`
- `ci_low_naive`
- `ci_high_naive`

The event-study plot omits naive bands by default. If needed for a quick
descriptive check, set:

```powershell
$env:BJS_PLOT_NAIVE_BANDS="1"
```

For exploratory uncertainty checks, `199` bootstrap replications are acceptable.
For paper-facing tables, use `499` replications when runtime permits. `999`
is preferable only if the runtime burden is realistic:

```powershell
$env:BJS_BOOTSTRAP_REPS="499"
$env:BJS_BOOTSTRAP_SAMPLES="overall,official_before_yes,official_before_no,gte13,preobs_ge12"
Rscript "C:\Users\mitsu\kenkyu\RPackagenameconfusion\analysis\script\method_bjs_imputation_v1.R"
```

Outputs:

- `bjs_bootstrap_draws.csv`
- `bjs_bootstrap_summary.csv`
- `bjs_inference_status.csv`
- `bjs_bootstrap_draws_<sample>.csv`
- `bjs_bootstrap_summary_<sample>.csv`

The bootstrap resamples packages with replacement and re-estimates the
untreated-outcome FE model in each draw. This should be described as
package-cluster bootstrap inference for the reported BJS imputation estimands.
Do not describe it as the closed-form BJS conservative variance estimator.

If `bjs_inference_status.csv` says `paper_facing_inference_available = FALSE`,
do not use the ATT confidence intervals as paper-facing inference.

Bootstrap checkpoints are saved during execution. By default, each completed
draw is saved to sample-specific checkpoint files:

```text
bjs_bootstrap_draws_overall.csv
bjs_bootstrap_summary_overall.csv
...
```

If the process is interrupted, re-run the same command and the script will skip
draws already present in the checkpoint files. To ignore checkpoints and start
over:

```powershell
$env:BJS_BOOTSTRAP_RESUME="0"
```

To reduce disk writes, checkpoint less often:

```powershell
$env:BJS_BOOTSTRAP_CHECKPOINT_EVERY="25"
```

If `499` is too costly, use `199` for exploratory analysis with a clear note
that inference is provisional.

## Support checks

Before interpreting long-run effects, check:

- `bjs_timing_check_summary.csv`
- `bjs_timing_check_head.csv`
- `bjs_period_untreated_support.csv`
- `bjs_dynamic_all.csv`
- `bjs_control_composition.csv`

These files guard against timing misalignment, weak untreated support at long
horizons, and subgroup control-composition problems.

The treatment-timing check is especially important because the script shifts
treated `G` by +1 when the cached panel uses 0-based periods. Before
interpreting estimates, confirm:

```text
bjs_timing_status.csv:
  timing_alignment_ok = TRUE

bjs_timing_check_summary.csv:
  first_post_not_equal_G = 0
```

`missing_first_post` can be positive when treated packages have no post
observations inside the analysis window. That is a support issue, not
necessarily a one-period timing shift. If `first_post_not_equal_G` is positive,
event time may be shifted by one period and the estimates should not be
interpreted until timing is reconciled with the C&S panel definition.

## Recommended production commands

Point estimates, diagnostics, and BJS pretrend test. This does not produce
paper-facing ATT inference unless bootstrap is requested:

```powershell
Rscript "C:\Users\mitsu\kenkyu\RPackagenameconfusion\analysis\script\method_bjs_imputation_v1.R"
```

Paper-facing run with bootstrap:

```powershell
$env:BJS_BOOTSTRAP_REPS="199"
$env:BJS_BOOTSTRAP_SAMPLES="overall,official_before_yes,official_before_no,gte13,preobs_ge12"
Rscript "C:\Users\mitsu\kenkyu\RPackagenameconfusion\analysis\script\method_bjs_imputation_v1.R"
```

Quick debug run:

```powershell
$env:BJS_DEBUG_TAG="debug"
$env:BJS_SAMPLE_TREATED_N="80"
$env:BJS_SAMPLE_NEVER_N="200"
$env:BJS_FE_MAX_ITER="80"
$env:BJS_SKIP_PLOT="1"
Rscript "C:\Users\mitsu\kenkyu\RPackagenameconfusion\analysis\script\method_bjs_imputation_v1.R"
```

Clear temporary environment variables before production if the same PowerShell
session was used for debugging.
