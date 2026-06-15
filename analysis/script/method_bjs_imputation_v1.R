# BJS-style imputation event study for the R package name-confusion project.
#
# This script estimates untreated potential outcomes from untreated observations
# using package and period fixed effects, then aggregates imputation residuals by
# event time. It is intentionally self-contained and diagnostic-heavy so the
# estimand can be compared carefully against the existing C&S DID results.

suppressPackageStartupMessages({
  library(ggplot2)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args, value = TRUE)
script_path <- if (length(file_arg) > 0) {
  normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE)
} else {
  normalizePath(file.path(getwd(), "analysis", "script", "method_bjs_imputation_v1.R"), winslash = "/", mustWork = FALSE)
}

find_project_root <- function(start_dir) {
  cur <- normalizePath(start_dir, winslash = "/", mustWork = FALSE)
  for (i in seq_len(8L)) {
    if (dir.exists(file.path(cur, "figures")) && dir.exists(file.path(cur, "analysis"))) return(cur)
    parent <- normalizePath(file.path(cur, ".."), winslash = "/", mustWork = FALSE)
    if (identical(parent, cur)) break
    cur <- parent
  }
  cwd <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  candidates <- c(cwd, file.path(cwd, "RPackagenameconfusion"))
  for (cand in candidates) {
    if (dir.exists(file.path(cand, "figures")) && dir.exists(file.path(cand, "analysis"))) {
      return(normalizePath(cand, winslash = "/", mustWork = FALSE))
    }
  }
  stop("Could not locate project root with both figures/ and analysis/ directories.")
}

base_dir <- find_project_root(dirname(script_path))

input_dir <- file.path(base_dir, "figures", "cs2021_did_r_v8")
panel_cache_file <- file.path(input_dir, "panel_cache_v8.rds")
out_dir <- file.path(input_dir, "bjs_imputation")
log_file <- file.path(out_dir, "bjs_run_progress.log")

log_msg <- function(...) {
  ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  msg <- paste0("[", ts, "] ", paste(..., collapse = " "))
  cat(msg, "\n")
  cat(msg, "\n", file = log_file, append = TRUE)
  flush.console()
}

env_alias <- function(name) {
  sub("^CS2021_BJS_", "BJS_", name)
}

get_env_value <- function(name, default = "") {
  alias <- env_alias(name)
  alias_val <- Sys.getenv(alias, "")
  if (nzchar(alias_val)) return(alias_val)
  Sys.getenv(name, default)
}

get_env_int <- function(name, default) {
  out <- suppressWarnings(as.integer(get_env_value(name, as.character(default))))
  if (is.na(out)) as.integer(default) else out
}

get_env_flag <- function(name, default = FALSE) {
  val <- get_env_value(name, if (default) "1" else "0")
  tolower(val) %in% c("1", "true", "yes", "y", "on")
}

get_env_int_vec <- function(name, default) {
  val <- get_env_value(name, "")
  if (!nzchar(val)) return(as.integer(default))
  out <- suppressWarnings(as.integer(strsplit(val, "[, ]+")[[1]]))
  out <- out[!is.na(out)]
  if (length(out) == 0L) as.integer(default) else out
}

get_env_chr_vec <- function(name, default) {
  val <- get_env_value(name, "")
  if (!nzchar(val)) return(default)
  out <- trimws(strsplit(val, "[,; ]+")[[1]])
  out[nzchar(out)]
}

cfg <- list(
  event_min = get_env_int("CS2021_BJS_EVENT_MIN", -24L),
  event_max = get_env_int("CS2021_BJS_EVENT_MAX", 60L),
  balanced_e_values = get_env_int_vec("CS2021_BJS_BALANCED_E_VALUES", c(12L, 24L, 36L, 48L)),
  max_period = get_env_int("CS2021_BJS_MAX_PERIOD", 120L),
  min_cohort_size = get_env_int("CS2021_BJS_MIN_COHORT_SIZE", 0L),
  max_post_period = get_env_int("CS2021_BJS_MAX_POST_PERIOD", 60L),
  max_iter = get_env_int("CS2021_BJS_FE_MAX_ITER", 200L),
  tol = as.numeric(get_env_value("CS2021_BJS_FE_TOL", "1e-8")),
  min_pre_obs = get_env_int("CS2021_BJS_MIN_PRE_OBS", 1L),
  pretest_k = get_env_int("CS2021_BJS_PRETEST_K", 12L),
  sample_treated_n = get_env_int("CS2021_BJS_SAMPLE_TREATED_N", 0L),
  sample_never_n = get_env_int("CS2021_BJS_SAMPLE_NEVER_N", 0L),
  run_subgroup = get_env_flag("CS2021_BJS_RUN_SUBGROUP", TRUE),
  run_sensitivity = get_env_flag("CS2021_BJS_RUN_SENSITIVITY", TRUE),
  run_pretrend_test = get_env_flag("CS2021_BJS_RUN_PRETREND_TEST", TRUE),
  bootstrap_reps = get_env_int("CS2021_BJS_BOOTSTRAP_REPS", 0L),
  bootstrap_samples = get_env_chr_vec("CS2021_BJS_BOOTSTRAP_SAMPLES", c("overall", "official_before_yes", "official_before_no", "gte13", "preobs_ge12")),
  bootstrap_checkpoint_every = get_env_int("CS2021_BJS_BOOTSTRAP_CHECKPOINT_EVERY", 1L),
  bootstrap_resume = get_env_flag("CS2021_BJS_BOOTSTRAP_RESUME", TRUE),
  sensitivity_only = get_env_flag("CS2021_BJS_SENSITIVITY_ONLY", FALSE),
  diag_only = get_env_flag("CS2021_BJS_DIAG_ONLY", FALSE),
  skip_plot = get_env_flag("CS2021_BJS_SKIP_PLOT", FALSE),
  plot_naive_bands = get_env_flag("CS2021_BJS_PLOT_NAIVE_BANDS", FALSE),
  force_recompute = get_env_flag("CS2021_BJS_FORCE_RECOMPUTE", FALSE)
)

if (!is.finite(cfg$tol) || cfg$tol <= 0) cfg$tol <- 1e-8
if (cfg$sensitivity_only) cfg$run_sensitivity <- TRUE
debug_tag <- get_env_value("CS2021_BJS_DEBUG_TAG", "")
if (nzchar(debug_tag)) {
  out_dir <- file.path(out_dir, paste0("debug_", debug_tag))
  log_file <- file.path(out_dir, "bjs_run_progress.log")
}
if (cfg$sample_treated_n > 0L || cfg$sample_never_n > 0L) {
  out_dir <- file.path(out_dir, "debug_sample")
  log_file <- file.path(out_dir, "bjs_run_progress.log")
}
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

write_csv <- function(x, path) {
  write.csv(x, path, row.names = FALSE, fileEncoding = "UTF-8")
  log_msg("saved:", path)
}

write_csv_quiet <- function(x, path) {
  write.csv(x, path, row.names = FALSE, fileEncoding = "UTF-8")
}

write_config <- function() {
  cfg_df <- data.frame(
    name = names(cfg),
    value = vapply(cfg, function(x) paste(x, collapse = ","), character(1)),
    stringsAsFactors = FALSE
  )
  write_csv(cfg_df, file.path(out_dir, "bjs_run_config.csv"))
}

write_method_notes <- function() {
  notes <- c(
    "BJS imputation v1 notes for comparison with the existing C&S DID v8 results",
    "",
    "Estimator:",
    "  BJS-style imputation event study.",
    "  Untreated potential outcomes are estimated from untreated observations only.",
    "  The untreated outcome model is package fixed effects + period fixed effects.",
    "",
    "Untreated observations:",
    "  G == 0, or period < G for future-treated packages.",
    "",
    "Event time:",
    "  event_time = period - G for treated packages.",
    "  G is shifted by +1 when the cached panel uses 0-based periods, matching the existing C&S DID script.",
    "  This timing alignment is a high-risk assumption; check bjs_timing_check_head.csv before interpreting results.",
    "",
    "Aggregation:",
    "  bjs_summary.csv reports both event-time equal-weighted and observation-weighted dynamic ATT.",
    "  Use dynamic_att_event_equal_0_60 for the first comparison with C&S dynamic ATT.",
    "  bjs_balanced_summary.csv similarly reports att_event_equal and att_obs_weighted.",
    "",
    "Inference:",
    "  Naive SEs are retained only as descriptive diagnostics and are explicitly labeled *_naive.",
    "  They are not cluster/conservative BJS standard errors and should not be used as final inference.",
    "  Paper-facing inference should use bjs_bootstrap_summary.csv when BJS_BOOTSTRAP_REPS > 0.",
    "  The bootstrap re-estimates the untreated-outcome FE model within each resampled package-cluster sample.",
    "  Bootstrap outputs are pragmatic package-cluster bootstrap inference for reported estimands.",
    "  Do not describe them as the closed-form BJS conservative variance estimator.",
    "  Use BJS_BOOTSTRAP_REPS=199 for exploration; use 499 or 999 for paper-facing tables when feasible.",
    "  Bootstrap checkpoints are saved by sample as bjs_bootstrap_draws_<sample>.csv and bjs_bootstrap_summary_<sample>.csv.",
    "  Set BJS_BOOTSTRAP_CHECKPOINT_EVERY to control checkpoint frequency; default is every draw.",
    "  Set BJS_BOOTSTRAP_RESUME=0 to ignore existing checkpoints.",
    "  The event-study plot omits naive bands by default; set BJS_PLOT_NAIVE_BANDS=1 only for descriptive checks.",
    "",
    "Pre-event diagnostics:",
    "  bjs_pre_event_diagnostics.csv reports pre-event imputation residuals by event time.",
    "  These are diagnostics, not a final formal pre-trend/no-anticipation test.",
    "  They are not the formal BJS pre-trend/no-anticipation test because the FE model is fit using untreated observations including pre-treatment observations.",
    "",
    "BJS pre-trend/no-anticipation test:",
    "  bjs_pretrend_test_summary.csv and bjs_pretrend_test_coefficients.csv implement the BJS Test 1 idea.",
    "  They estimate log_dl on package FE, period FE, and indicators for 1..k periods before treatment using untreated observations only.",
    "  The reported Wald test is cluster-robust by package. Treat it as the paper-aligned pre-trend diagnostic.",
    "  Set BJS_PRETEST_K or CS2021_BJS_PRETEST_K to change k; the default is 12.",
    "",
    "Support diagnostics:",
    "  bjs_period_untreated_support.csv reports untreated support by calendar period.",
    "  bjs_dynamic_all.csv reports n_obs and n_packages by event time.",
    "  bjs_control_composition.csv reports never-treated and future-treated control composition for each sample.",
    "",
    "Next verification:",
    "  Compare signs and dynamic paths against C&S.",
    "  If the estimates are used in a paper, add cluster/bootstrap inference or a package implementation check."
  )
  path <- file.path(out_dir, "bjs_method_notes.txt")
  writeLines(notes, path, useBytes = TRUE)
  log_msg("saved:", path)
}

write_timing_checks <- function(panel) {
  treated <- panel[panel$G > 0L, c("package", "period", "G", "post", "event_time")]
  if (nrow(treated) == 0L) return(invisible(NULL))

  min_period <- aggregate(period ~ package + G, data = treated, FUN = min)
  names(min_period)[3] <- "min_period"
  max_period <- aggregate(period ~ package + G, data = treated, FUN = max)
  names(max_period)[3] <- "max_period"
  first_post <- aggregate(period ~ package + G, data = treated[treated$post, , drop = FALSE], FUN = min)
  names(first_post)[3] <- "first_post_period"
  min_event <- aggregate(event_time ~ package + G, data = treated, FUN = min)
  names(min_event)[3] <- "min_event_time"
  max_event <- aggregate(event_time ~ package + G, data = treated, FUN = max)
  names(max_event)[3] <- "max_event_time"

  timing <- Reduce(function(x, y) merge(x, y, by = c("package", "G"), all = TRUE),
    list(min_period, max_period, first_post, min_event, max_event))
  timing <- timing[order(timing$G, timing$package), ]
  write_csv(head(timing, 200), file.path(out_dir, "bjs_timing_check_head.csv"))

  timing_summary <- data.frame(
    treated_packages = nrow(timing),
    min_G = min(timing$G, na.rm = TRUE),
    max_G = max(timing$G, na.rm = TRUE),
    first_post_not_equal_G = sum(timing$first_post_period != timing$G, na.rm = TRUE),
    missing_first_post = sum(is.na(timing$first_post_period)),
    min_event_time = min(timing$min_event_time, na.rm = TRUE),
    max_event_time = max(timing$max_event_time, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
  write_csv(timing_summary, file.path(out_dir, "bjs_timing_check_summary.csv"))
  timing_status <- data.frame(
    timing_alignment_ok = timing_summary$first_post_not_equal_G == 0L,
    first_post_not_equal_G = timing_summary$first_post_not_equal_G,
    missing_first_post = timing_summary$missing_first_post,
    interpretation = if (timing_summary$first_post_not_equal_G == 0L && timing_summary$missing_first_post == 0L) {
      "OK: first post period equals G for all treated packages with post observations."
    } else if (timing_summary$first_post_not_equal_G == 0L) {
      "OK with missing post observations: first post period equals G whenever post observations exist; missing_first_post reflects treated packages without post observations in the analysis window."
    } else {
      "WARNING: treatment timing alignment needs manual inspection before interpreting event-time estimates."
    },
    stringsAsFactors = FALSE
  )
  write_csv(timing_status, file.path(out_dir, "bjs_timing_status.csv"))
  if (!isTRUE(timing_status$timing_alignment_ok)) {
    log_msg("WARNING: timing alignment check failed; inspect bjs_timing_check_summary.csv and bjs_timing_check_head.csv")
  } else if (timing_status$missing_first_post > 0L) {
    log_msg("timing alignment OK for treated packages with post observations; missing_first_post=", timing_status$missing_first_post)
  }
}

write_period_support <- function(panel) {
  rows <- lapply(sort(unique(panel$period)), function(p) {
    sub <- panel[panel$period == p, , drop = FALSE]
    data.frame(
      period = p,
      observations = nrow(sub),
      packages = length(unique(sub$package)),
      untreated_observations = sum(sub$untreated_obs),
      untreated_packages = length(unique(sub$package[sub$untreated_obs])),
      never_packages = length(unique(sub$package[sub$G == 0L])),
      future_treated_untreated_packages = length(unique(sub$package[sub$G > p])),
      post_treated_observations = sum(sub$post),
      stringsAsFactors = FALSE
    )
  })
  support <- do.call(rbind, rows)
  write_csv(support, file.path(out_dir, "bjs_period_untreated_support.csv"))
}

normalize_panel <- function(panel) {
  need_cols <- c("package", "period", "G", "log_dl", "official_before_event")
  miss <- setdiff(need_cols, names(panel))
  if (length(miss) > 0L) {
    stop("panel missing required columns: ", paste(miss, collapse = ", "))
  }

  panel$package <- as.character(panel$package)
  panel$period <- as.integer(panel$period)
  panel$G <- as.integer(panel$G)
  panel$log_dl <- as.numeric(panel$log_dl)
  panel$official_before_event <- as.integer(panel$official_before_event)
  panel$official_before_event[is.na(panel$official_before_event)] <- 0L

  if (min(panel$period, na.rm = TRUE) == 0L) {
    treated_idx <- panel$G > 0L
    panel$G[treated_idx] <- panel$G[treated_idx] + 1L
    log_msg("normalize: shifted treated G by +1 to match existing did script indexing; period left unchanged")
  }

  if (cfg$max_period >= 0L) {
    before <- nrow(panel)
    panel <- panel[panel$period <= cfg$max_period, , drop = FALSE]
    log_msg(sprintf("normalize: max_period=%d rows %d -> %d", cfg$max_period, before, nrow(panel)))
  }

  panel$treated_unit <- panel$G > 0L
  panel$post <- panel$treated_unit & panel$period >= panel$G
  panel$untreated_obs <- (!panel$treated_unit) | panel$period < panel$G
  panel$event_time <- ifelse(panel$treated_unit, panel$period - panel$G, NA_integer_)

  panel
}

sample_panel_for_debug <- function(panel) {
  sample_treated_n <- as.integer(cfg$sample_treated_n)
  sample_never_n <- as.integer(cfg$sample_never_n)
  if (is.na(sample_treated_n) || sample_treated_n < 0L) sample_treated_n <- 0L
  if (is.na(sample_never_n) || sample_never_n < 0L) sample_never_n <- 0L
  if (sample_treated_n == 0L && sample_never_n == 0L) return(panel)

  set.seed(20260613)
  treated_pkgs <- sort(unique(panel$package[panel$G > 0L]))
  never_pkgs <- sort(unique(panel$package[panel$G == 0L]))

  keep_treated <- if (sample_treated_n > 0L && length(treated_pkgs) > sample_treated_n) {
    sample(treated_pkgs, sample_treated_n)
  } else {
    treated_pkgs
  }
  keep_never <- if (sample_never_n > 0L && length(never_pkgs) > sample_never_n) {
    sample(never_pkgs, sample_never_n)
  } else {
    never_pkgs
  }

  keep <- c(keep_treated, keep_never)
  out <- panel[panel$package %in% keep, , drop = FALSE]
  log_msg(sprintf("debug sample: treated %d/%d, never %d/%d, rows %d -> %d",
    length(keep_treated), length(treated_pkgs), length(keep_never), length(never_pkgs), nrow(panel), nrow(out)))
  out
}

apply_stability_filters <- function(panel) {
  out <- panel

  min_cohort_size <- as.integer(cfg$min_cohort_size)
  if (is.na(min_cohort_size) || min_cohort_size < 0L) min_cohort_size <- 0L
  if (min_cohort_size > 0L) {
    pkg_g <- unique(out[, c("package", "G")])
    treated <- pkg_g[pkg_g$G > 0L, , drop = FALSE]
    cohort_n <- aggregate(package ~ G, data = treated, FUN = length)
    names(cohort_n)[2] <- "n_packages"
    keep_g <- cohort_n$G[cohort_n$n_packages >= min_cohort_size]
    before <- length(unique(out$package[out$G > 0L]))
    out <- out[out$G == 0L | out$G %in% keep_g, , drop = FALSE]
    after <- length(unique(out$package[out$G > 0L]))
    log_msg(sprintf("stability filter: min_cohort_size=%d treated packages %d -> %d", min_cohort_size, before, after))
  }

  max_post_period <- as.integer(cfg$max_post_period)
  if (is.na(max_post_period)) max_post_period <- -1L
  if (max_post_period >= 0L) {
    before <- nrow(out)
    out <- out[(out$G == 0L) | (out$period <= out$G + max_post_period), , drop = FALSE]
    after <- nrow(out)
    log_msg(sprintf("stability filter: max_post_period=%d rows %d -> %d", max_post_period, before, after))
  }

  out$post <- out$treated_unit & out$period >= out$G
  out$untreated_obs <- (!out$treated_unit) | out$period < out$G
  out$event_time <- ifelse(out$treated_unit, out$period - out$G, NA_integer_)
  out
}

estimate_twfe_untreated <- function(df, tag) {
  untreated <- df[df$untreated_obs & is.finite(df$log_dl), c("package", "period", "log_dl")]
  if (nrow(untreated) == 0L) stop("[", tag, "] no untreated observations")

  packages <- sort(unique(df$package))
  periods <- sort(unique(df$period))
  untreated$package <- factor(untreated$package, levels = packages)
  untreated$period <- factor(untreated$period, levels = periods)

  pkg_id <- as.integer(untreated$package)
  time_id <- as.integer(untreated$period)
  y <- untreated$log_dl

  mu <- mean(y, na.rm = TRUE)
  alpha <- rep(0, length(packages))
  lambda <- rep(0, length(periods))

  pkg_count <- tabulate(pkg_id, nbins = length(packages))
  time_count <- tabulate(time_id, nbins = length(periods))

  if (any(pkg_count == 0L)) {
    log_msg(sprintf("[%s] warning: %d packages have no untreated observations; predictions will be NA", tag, sum(pkg_count == 0L)))
  }
  if (any(time_count == 0L)) {
    log_msg(sprintf("[%s] warning: %d periods have no untreated observations; predictions will be NA", tag, sum(time_count == 0L)))
  }

  converged <- FALSE
  last_change <- Inf

  for (iter in seq_len(cfg$max_iter)) {
    old_alpha <- alpha
    old_lambda <- lambda

    alpha_sum <- rowsum(y - mu - lambda[time_id], pkg_id, reorder = TRUE)
    alpha_ids <- as.integer(rownames(alpha_sum))
    alpha_new <- rep(NA_real_, length(packages))
    alpha_new[alpha_ids] <- as.numeric(alpha_sum[, 1]) / pkg_count[alpha_ids]
    alpha_new[is.na(alpha_new)] <- 0
    alpha_new <- alpha_new - weighted.mean(alpha_new, pkg_count, na.rm = TRUE)
    alpha <- alpha_new

    lambda_sum <- rowsum(y - mu - alpha[pkg_id], time_id, reorder = TRUE)
    lambda_ids <- as.integer(rownames(lambda_sum))
    lambda_new <- rep(NA_real_, length(periods))
    lambda_new[lambda_ids] <- as.numeric(lambda_sum[, 1]) / time_count[lambda_ids]
    lambda_new[is.na(lambda_new)] <- 0
    lambda_new <- lambda_new - weighted.mean(lambda_new, time_count, na.rm = TRUE)
    lambda <- lambda_new

    last_change <- max(abs(alpha - old_alpha), abs(lambda - old_lambda), na.rm = TRUE)
    if (iter %% 25L == 0L || iter == 1L) {
      log_msg(sprintf("[%s] FE iter=%d max_change=%.3e", tag, iter, last_change))
    }
    if (last_change < cfg$tol) {
      converged <- TRUE
      log_msg(sprintf("[%s] FE converged iter=%d max_change=%.3e", tag, iter, last_change))
      break
    }
  }

  if (!converged) {
    log_msg(sprintf("[%s] warning: FE did not converge by iter=%d; max_change=%.3e", tag, cfg$max_iter, last_change))
  }

  list(
    mu = mu,
    packages = packages,
    periods = periods,
    alpha = alpha,
    lambda = lambda,
    pkg_has_untreated = pkg_count > 0L,
    period_has_untreated = time_count > 0L,
    converged = converged,
    last_change = last_change,
    untreated_n = nrow(untreated)
  )
}

predict_untreated <- function(df, fit) {
  pkg_id <- match(df$package, fit$packages)
  time_id <- match(df$period, fit$periods)
  pred <- fit$mu + fit$alpha[pkg_id] + fit$lambda[time_id]
  ok <- !is.na(pkg_id) & !is.na(time_id) &
    fit$pkg_has_untreated[pkg_id] & fit$period_has_untreated[time_id]
  pred[!ok] <- NA_real_
  pred
}

residualize_twfe_matrix <- function(mat, pkg_id, time_id, tag = "residualize") {
  mat <- as.matrix(mat)
  storage.mode(mat) <- "double"
  pkg_count <- tabulate(pkg_id)
  time_count <- tabulate(time_id)
  converged <- FALSE
  last_change <- Inf

  for (iter in seq_len(cfg$max_iter)) {
    old <- mat

    pkg_sum <- rowsum(mat, pkg_id, reorder = TRUE)
    pkg_mean <- pkg_sum / pkg_count[as.integer(rownames(pkg_sum))]
    mat <- mat - pkg_mean[match(pkg_id, as.integer(rownames(pkg_mean))), , drop = FALSE]

    time_sum <- rowsum(mat, time_id, reorder = TRUE)
    time_mean <- time_sum / time_count[as.integer(rownames(time_sum))]
    mat <- mat - time_mean[match(time_id, as.integer(rownames(time_mean))), , drop = FALSE]

    last_change <- max(abs(mat - old), na.rm = TRUE)
    if (iter %% 25L == 0L || iter == 1L) {
      log_msg(sprintf("[%s] residualize iter=%d max_change=%.3e", tag, iter, last_change))
    }
    if (last_change < cfg$tol) {
      converged <- TRUE
      break
    }
  }

  if (!converged) {
    log_msg(sprintf("[%s] warning: residualization did not converge by iter=%d; max_change=%.3e",
      tag, cfg$max_iter, last_change))
  }
  mat
}

cluster_vcov <- function(x, u, cluster) {
  x <- as.matrix(x)
  u <- as.numeric(u)
  ok <- stats::complete.cases(x) & is.finite(u)
  x <- x[ok, , drop = FALSE]
  u <- u[ok]
  cluster <- cluster[ok]
  n <- nrow(x)
  k <- ncol(x)
  clusters <- unique(cluster)
  m <- length(clusters)
  xtx_inv <- tryCatch(solve(crossprod(x)), error = function(e) MASS_qr_inv(crossprod(x)))
  meat <- matrix(0, k, k)
  for (cl in clusters) {
    idx <- cluster == cl
    xu <- crossprod(x[idx, , drop = FALSE], u[idx])
    meat <- meat + tcrossprod(xu)
  }
  scale <- if (m > 1L && n > k) (m / (m - 1L)) * ((n - 1L) / (n - k)) else 1
  scale * xtx_inv %*% meat %*% xtx_inv
}

MASS_qr_inv <- function(a) {
  out <- tryCatch(qr.solve(a, diag(nrow(a))), error = function(e) NULL)
  if (!is.null(out)) return(out)
  eig <- eigen((a + t(a)) / 2, symmetric = TRUE)
  tol <- max(abs(eig$values), na.rm = TRUE) * 1e-10
  keep <- eig$values > tol
  if (!any(keep)) return(matrix(NA_real_, nrow(a), ncol(a)))
  eig$vectors[, keep, drop = FALSE] %*%
    diag(1 / eig$values[keep], nrow = sum(keep)) %*%
    t(eig$vectors[, keep, drop = FALSE])
}

bind_nonempty <- function(items) {
  items <- items[vapply(items, function(x) is.data.frame(x) && nrow(x) > 0L, logical(1))]
  if (length(items) == 0L) return(data.frame())
  do.call(rbind, items)
}

run_bjs_pretrend_test <- function(df, tag, sample_label) {
  k <- as.integer(cfg$pretest_k)
  if (is.na(k) || k <= 0L) {
    return(list(summary = data.frame(), coefficients = data.frame()))
  }

  untreated <- df[df$untreated_obs & is.finite(df$log_dl), , drop = FALSE]
  if (nrow(untreated) == 0L) {
    return(list(summary = data.frame(), coefficients = data.frame()))
  }

  pre_distance <- ifelse(untreated$treated_unit, untreated$G - untreated$period, NA_integer_)
  w <- matrix(0, nrow = nrow(untreated), ncol = k)
  for (j in seq_len(k)) {
    w[, j] <- as.numeric(!is.na(pre_distance) & pre_distance == j)
  }
  colnames(w) <- paste0("lead_", seq_len(k))

  active <- colSums(w) > 0
  if (!any(active)) {
    return(list(summary = data.frame(
      tag = tag,
      sample = sample_label,
      k = k,
      n_obs = nrow(untreated),
      n_clusters = length(unique(untreated$package)),
      n_coefficients = 0L,
      wald_stat = NA_real_,
      df = 0L,
      p_value = NA_real_,
      stringsAsFactors = FALSE
    ), coefficients = data.frame()))
  }
  w <- w[, active, drop = FALSE]

  pkg_levels <- sort(unique(untreated$package))
  time_levels <- sort(unique(untreated$period))
  pkg_id <- match(untreated$package, pkg_levels)
  time_id <- match(untreated$period, time_levels)

  y_res <- residualize_twfe_matrix(matrix(untreated$log_dl, ncol = 1), pkg_id, time_id, tag = paste0(tag, "_pretest_y"))[, 1]
  x_res <- residualize_twfe_matrix(w, pkg_id, time_id, tag = paste0(tag, "_pretest_w"))

  qr_x <- qr(x_res)
  rank_x <- qr_x$rank
  if (rank_x == 0L) {
    return(list(summary = data.frame(
      tag = tag,
      sample = sample_label,
      k = k,
      n_obs = nrow(untreated),
      n_clusters = length(unique(untreated$package)),
      n_coefficients = 0L,
      wald_stat = NA_real_,
      df = 0L,
      p_value = NA_real_,
      stringsAsFactors = FALSE
    ), coefficients = data.frame()))
  }
  if (rank_x < ncol(x_res)) {
    keep <- qr_x$pivot[seq_len(rank_x)]
    x_res <- x_res[, sort(keep), drop = FALSE]
  }

  gamma <- as.numeric(qr.solve(x_res, y_res))
  names(gamma) <- colnames(x_res)
  resid <- y_res - as.numeric(x_res %*% gamma)
  vc <- cluster_vcov(x_res, resid, untreated$package)
  se <- sqrt(pmax(diag(vc), 0))
  wald <- as.numeric(t(gamma) %*% MASS_qr_inv(vc) %*% gamma)
  df_wald <- length(gamma)
  p_value <- stats::pchisq(wald, df = df_wald, lower.tail = FALSE)

  coef_df <- data.frame(
    tag = tag,
    sample = sample_label,
    term = names(gamma),
    estimate = gamma,
    se_cluster_package = se,
    t_value = gamma / se,
    p_value = 2 * stats::pnorm(abs(gamma / se), lower.tail = FALSE),
    stringsAsFactors = FALSE
  )
  coef_df$ci_low <- coef_df$estimate - 1.96 * coef_df$se_cluster_package
  coef_df$ci_high <- coef_df$estimate + 1.96 * coef_df$se_cluster_package

  summary_df <- data.frame(
    tag = tag,
    sample = sample_label,
    k = k,
    n_obs = nrow(untreated),
    n_clusters = length(unique(untreated$package)),
    n_coefficients = length(gamma),
    wald_stat = wald,
    df = df_wald,
    p_value = p_value,
    stringsAsFactors = FALSE
  )

  list(summary = summary_df, coefficients = coef_df)
}

pre_obs_by_package <- function(df) {
  out <- aggregate(untreated_obs ~ package, data = df[df$treated_unit, ], FUN = sum)
  names(out)[2] <- "pre_obs"
  out
}

add_pre_obs <- function(df) {
  pre_counts <- pre_obs_by_package(df)
  out <- merge(df, pre_counts, by = "package", all.x = TRUE)
  out$pre_obs[is.na(out$pre_obs)] <- Inf
  out
}

aggregate_event <- function(df, tag, sample_label) {
  keep <- df$treated_unit &
    is.finite(df$resid_bjs) &
    !is.na(df$event_time) &
    df$event_time >= cfg$event_min &
    df$event_time <= cfg$event_max
  ev <- df[keep, c("package", "event_time", "resid_bjs", "post")]
  if (nrow(ev) == 0L) {
    return(data.frame())
  }

  event_values <- sort(unique(ev$event_time))
  rows <- lapply(event_values, function(e) {
    sub <- ev[ev$event_time == e, , drop = FALSE]
      data.frame(
        tag = tag,
        sample = sample_label,
        event_time = e,
        att = mean(sub$resid_bjs, na.rm = TRUE),
        se_naive = stats::sd(sub$resid_bjs, na.rm = TRUE) / sqrt(nrow(sub)),
        n_obs = nrow(sub),
        n_packages = length(unique(sub$package)),
        post = e >= 0L,
        stringsAsFactors = FALSE
      )
  })
  out <- do.call(rbind, rows)
  out$ci_low_naive <- out$att - 1.96 * out$se_naive
  out$ci_high_naive <- out$att + 1.96 * out$se_naive
  out
}

summary_from_event <- function(event_df, tag, sample_label) {
  if (nrow(event_df) == 0L) return(data.frame())
  post <- event_df[event_df$event_time >= 0L & event_df$event_time <= cfg$event_max, , drop = FALSE]
  pre <- event_df[event_df$event_time < 0L, , drop = FALSE]

  weighted_mean <- function(x, w) {
    if (length(x) == 0L || sum(w, na.rm = TRUE) == 0) return(NA_real_)
    sum(x * w, na.rm = TRUE) / sum(w, na.rm = TRUE)
  }

  data.frame(
    tag = tag,
    sample = sample_label,
    dynamic_att_event_equal_0_60 = if (nrow(post) > 0L) mean(post$att, na.rm = TRUE) else NA_real_,
    dynamic_att_obs_weighted_0_60 = weighted_mean(post$att, post$n_obs),
    mean_pre_att_event_equal = if (nrow(pre) > 0L) mean(pre$att, na.rm = TRUE) else NA_real_,
    mean_pre_att_obs_weighted = weighted_mean(pre$att, pre$n_obs),
    max_abs_pre_att = if (nrow(pre) > 0L) max(abs(pre$att), na.rm = TRUE) else NA_real_,
    pre_event_cells = nrow(pre),
    post_event_cells = nrow(post),
    post_obs = sum(post$n_obs, na.rm = TRUE),
    pre_obs = sum(pre$n_obs, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

balanced_summary <- function(df, tag, sample_label, horizons = cfg$balanced_e_values) {
  rows <- lapply(horizons, function(h) {
    treated_pkgs <- unique(df$package[df$treated_unit])
    pkg_max_event <- aggregate(event_time ~ package, data = df[df$treated_unit, ], FUN = max, na.rm = TRUE)
    keep_pkgs <- pkg_max_event$package[pkg_max_event$event_time >= h]
    sub <- df[df$package %in% keep_pkgs &
      df$treated_unit &
      df$post &
      df$event_time >= 0L &
      df$event_time <= h &
      is.finite(df$resid_bjs), , drop = FALSE]
    event_att <- if (nrow(sub) > 0L) {
      aggregate(resid_bjs ~ event_time, data = sub, FUN = mean)
    } else {
      data.frame(event_time = integer(), resid_bjs = numeric())
    }
    data.frame(
      tag = tag,
      sample = sample_label,
      horizon = h,
      att_event_equal = if (nrow(event_att) > 0L) mean(event_att$resid_bjs, na.rm = TRUE) else NA_real_,
      se_event_equal_naive = if (nrow(event_att) > 1L) stats::sd(event_att$resid_bjs, na.rm = TRUE) / sqrt(nrow(event_att)) else NA_real_,
      att_obs_weighted = if (nrow(sub) > 0L) mean(sub$resid_bjs, na.rm = TRUE) else NA_real_,
      se_obs_weighted_naive = if (nrow(sub) > 1L) stats::sd(sub$resid_bjs, na.rm = TRUE) / sqrt(nrow(sub)) else NA_real_,
      n_obs = nrow(sub),
      n_packages = length(unique(sub$package)),
      treated_packages_available = length(treated_pkgs),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out$ci_low_event_equal_naive <- out$att_event_equal - 1.96 * out$se_event_equal_naive
  out$ci_high_event_equal_naive <- out$att_event_equal + 1.96 * out$se_event_equal_naive
  out$ci_low_obs_weighted_naive <- out$att_obs_weighted - 1.96 * out$se_obs_weighted_naive
  out$ci_high_obs_weighted_naive <- out$att_obs_weighted + 1.96 * out$se_obs_weighted_naive
  out
}

diagnose_sample <- function(df, tag, sample_label, fit) {
  pkg_level <- unique(df[, c("package", "G", "official_before_event", "treated_unit")])
  pkg_post <- aggregate(post ~ package, data = df, FUN = any)
  names(pkg_post)[2] <- "has_post_observation"
  pkg_level <- merge(pkg_level, pkg_post, by = "package", all.x = TRUE)
  pkg_level$has_post_observation[is.na(pkg_level$has_post_observation)] <- FALSE
  pre_counts <- pre_obs_by_package(df)
  treated_pkg <- pkg_level[pkg_level$treated_unit, ]
  treated_pkg <- merge(treated_pkg, pre_counts, by = "package", all.x = TRUE)
  treated_pkg$pre_obs[is.na(treated_pkg$pre_obs)] <- 0L

  out <- data.frame(
    tag = tag,
    sample = sample_label,
    rows = nrow(df),
    packages = length(unique(df$package)),
    treated_packages = sum(pkg_level$treated_unit),
    treated_packages_with_post = sum(pkg_level$treated_unit & pkg_level$has_post_observation),
    never_packages = sum(!pkg_level$treated_unit),
    untreated_observations = sum(df$untreated_obs),
    post_treated_observations = sum(df$post),
    treated_packages_pre_obs_lt_min = sum(treated_pkg$pre_obs < cfg$min_pre_obs),
    fit_untreated_n = fit$untreated_n,
    fit_converged = fit$converged,
    fit_last_change = fit$last_change,
    stringsAsFactors = FALSE
  )
  out
}

sample_composition <- function(df, sample_label) {
  pkg_level <- unique(df[, c("package", "G", "official_before_event", "treated_unit")])
  pkg_post <- aggregate(post ~ package, data = df, FUN = any)
  names(pkg_post)[2] <- "has_post_observation"
  pkg_level <- merge(pkg_level, pkg_post, by = "package", all.x = TRUE)
  pkg_level$has_post_observation[is.na(pkg_level$has_post_observation)] <- FALSE

  data.frame(
    sample = sample_label,
    packages = nrow(pkg_level),
    treated_packages = sum(pkg_level$G > 0L),
    treated_packages_with_post = sum(pkg_level$G > 0L & pkg_level$has_post_observation),
    never_packages = sum(pkg_level$G == 0L),
    future_treated_packages = sum(pkg_level$G > 0L),
    official_before_yes_packages = sum(pkg_level$official_before_event == 1L),
    official_before_yes_treated = sum(pkg_level$official_before_event == 1L & pkg_level$G > 0L),
    official_before_yes_never = sum(pkg_level$official_before_event == 1L & pkg_level$G == 0L),
    official_before_no_treated = sum(pkg_level$official_before_event == 0L & pkg_level$G > 0L),
    official_before_no_never = sum(pkg_level$official_before_event == 0L & pkg_level$G == 0L),
    stringsAsFactors = FALSE
  )
}

run_bjs_one <- function(panel, tag, sample_label) {
  log_msg(sprintf("[%s] start sample=%s rows=%d packages=%d", tag, sample_label, nrow(panel), length(unique(panel$package))))

  fit <- estimate_twfe_untreated(panel, tag = tag)
  panel$y0_hat_bjs <- predict_untreated(panel, fit)
  panel$resid_bjs <- panel$log_dl - panel$y0_hat_bjs

  diag <- diagnose_sample(panel, tag, sample_label, fit)
  event_df <- aggregate_event(panel, tag, sample_label)
  summary_df <- summary_from_event(event_df, tag, sample_label)
  balanced_df <- balanced_summary(panel, tag, sample_label)
  pretrend <- if (isTRUE(cfg$run_pretrend_test)) {
    run_bjs_pretrend_test(panel, tag, sample_label)
  } else {
    list(summary = data.frame(), coefficients = data.frame())
  }

  list(
    diagnostics = diag,
    event = event_df,
    summary = summary_df,
    balanced = balanced_df,
    pretrend_summary = pretrend$summary,
    pretrend_coefficients = pretrend$coefficients
  )
}

run_bjs_point_only <- function(panel, tag, sample_label) {
  fit <- estimate_twfe_untreated(panel, tag = tag)
  panel$y0_hat_bjs <- predict_untreated(panel, fit)
  panel$resid_bjs <- panel$log_dl - panel$y0_hat_bjs
  event_df <- aggregate_event(panel, tag, sample_label)
  list(
    summary = summary_from_event(event_df, tag, sample_label),
    balanced = balanced_summary(panel, tag, sample_label)
  )
}

cluster_bootstrap_sample <- function(df, draw_id) {
  pkgs <- sort(unique(df$package))
  sampled <- sample(pkgs, length(pkgs), replace = TRUE)
  pieces <- vector("list", length(sampled))
  for (j in seq_along(sampled)) {
    sub <- df[df$package == sampled[j], , drop = FALSE]
    sub$package <- paste0(sub$package, "__boot", draw_id, "_", j)
    pieces[[j]] <- sub
  }
  do.call(rbind, pieces)
}

bootstrap_summarize <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0L) {
    return(c(mean = NA_real_, se = NA_real_, ci_low = NA_real_, ci_high = NA_real_, n_success = 0))
  }
  c(
    mean = mean(x),
    se = if (length(x) > 1L) stats::sd(x) else NA_real_,
    ci_low = as.numeric(stats::quantile(x, 0.025, names = FALSE, type = 6)),
    ci_high = as.numeric(stats::quantile(x, 0.975, names = FALSE, type = 6)),
    n_success = length(x)
  )
}

summarize_bootstrap_draws <- function(draws, reps) {
  if (!is.data.frame(draws) || nrow(draws) == 0L) return(data.frame())
  keys <- unique(draws[, c("sample", "estimand"), drop = FALSE])
  summary_rows <- lapply(seq_len(nrow(keys)), function(i) {
    sub <- draws[draws$sample == keys$sample[i] & draws$estimand == keys$estimand[i], , drop = FALSE]
    stats <- bootstrap_summarize(sub$value)
    data.frame(
      sample = keys$sample[i],
      estimand = keys$estimand[i],
      bootstrap_mean = stats[["mean"]],
      bootstrap_se = stats[["se"]],
      bootstrap_ci_low = stats[["ci_low"]],
      bootstrap_ci_high = stats[["ci_high"]],
      n_success = stats[["n_success"]],
      n_requested = reps,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, summary_rows)
}

bootstrap_checkpoint_paths <- function(sample_label) {
  safe <- gsub("[^A-Za-z0-9_\\-]+", "_", sample_label)
  list(
    draws = file.path(out_dir, paste0("bjs_bootstrap_draws_", safe, ".csv")),
    summary = file.path(out_dir, paste0("bjs_bootstrap_summary_", safe, ".csv"))
  )
}

read_bootstrap_checkpoint <- function(sample_label, reps = Inf) {
  paths <- bootstrap_checkpoint_paths(sample_label)
  if (!isTRUE(cfg$bootstrap_resume) || !file.exists(paths$draws)) return(data.frame())
  out <- tryCatch(
    read.csv(paths$draws, stringsAsFactors = FALSE, fileEncoding = "UTF-8"),
    error = function(e) {
      log_msg(sprintf("[bootstrap_%s] could not read checkpoint: %s", sample_label, conditionMessage(e)))
      data.frame()
    }
  )
  if (nrow(out) > 0L && "draw" %in% names(out)) {
    out$draw <- as.integer(out$draw)
    out <- out[out$draw <= reps, , drop = FALSE]
  }
  if (nrow(out) > 0L) {
    log_msg(sprintf("[bootstrap_%s] resume checkpoint found: %d rows, %d completed draws",
      sample_label, nrow(out), length(unique(out$draw))))
  }
  out
}

write_bootstrap_checkpoint <- function(sample_label, draws, reps) {
  if (!is.data.frame(draws) || nrow(draws) == 0L) return(invisible(NULL))
  paths <- bootstrap_checkpoint_paths(sample_label)
  write_csv_quiet(draws, paths$draws)
  summary <- summarize_bootstrap_draws(draws, reps)
  if (nrow(summary) > 0L) write_csv_quiet(summary, paths$summary)
  invisible(NULL)
}

run_bootstrap_one <- function(panel, sample_label) {
  reps <- as.integer(cfg$bootstrap_reps)
  if (is.na(reps) || reps <= 0L) return(list(draws = data.frame(), summary = data.frame()))
  checkpoint_every <- as.integer(cfg$bootstrap_checkpoint_every)
  if (is.na(checkpoint_every) || checkpoint_every <= 0L) checkpoint_every <- reps

  log_msg(sprintf("[bootstrap_%s] start reps=%d packages=%d rows=%d",
    sample_label, reps, length(unique(panel$package)), nrow(panel)))
  set.seed(20260614 + match(sample_label, sort(unique(c(sample_label, cfg$bootstrap_samples)))))

  checkpoint <- read_bootstrap_checkpoint(sample_label, reps)
  completed_draws <- if (nrow(checkpoint) > 0L) unique(as.integer(checkpoint$draw)) else integer()
  draw_rows <- if (nrow(checkpoint) > 0L) list(checkpoint) else list()
  for (b in seq_len(reps)) {
    if (b %in% completed_draws) next
    boot_df <- cluster_bootstrap_sample(panel, b)
    tag <- paste0("bootstrap_", sample_label, "_", b)
    point <- tryCatch(
      run_bjs_point_only(boot_df, tag = tag, sample_label = sample_label),
      error = function(e) {
        log_msg(sprintf("[bootstrap_%s] draw=%d failed: %s", sample_label, b, conditionMessage(e)))
        NULL
      }
    )
    if (is.null(point)) next

    sum_df <- point$summary
    if (nrow(sum_df) > 0L) {
      draw_rows[[length(draw_rows) + 1L]] <- data.frame(
        sample = sample_label,
        draw = b,
        estimand = "dynamic_att_event_equal_0_60",
        value = sum_df$dynamic_att_event_equal_0_60,
        stringsAsFactors = FALSE
      )
      draw_rows[[length(draw_rows) + 1L]] <- data.frame(
        sample = sample_label,
        draw = b,
        estimand = "dynamic_att_obs_weighted_0_60",
        value = sum_df$dynamic_att_obs_weighted_0_60,
        stringsAsFactors = FALSE
      )
    }

    bal_df <- point$balanced
    if (nrow(bal_df) > 0L) {
      for (i in seq_len(nrow(bal_df))) {
        draw_rows[[length(draw_rows) + 1L]] <- data.frame(
          sample = sample_label,
          draw = b,
          estimand = paste0("balanced_event_equal_h", bal_df$horizon[i]),
          value = bal_df$att_event_equal[i],
          stringsAsFactors = FALSE
        )
        draw_rows[[length(draw_rows) + 1L]] <- data.frame(
          sample = sample_label,
          draw = b,
          estimand = paste0("balanced_obs_weighted_h", bal_df$horizon[i]),
          value = bal_df$att_obs_weighted[i],
          stringsAsFactors = FALSE
        )
      }
    }

    if (b %% checkpoint_every == 0L || b == reps) {
      current_draws <- do.call(rbind, draw_rows)
      write_bootstrap_checkpoint(sample_label, current_draws, reps)
      log_msg(sprintf("[bootstrap_%s] checkpoint saved at draw=%d/%d", sample_label, b, reps))
    }
  }

  if (length(draw_rows) == 0L) return(list(draws = data.frame(), summary = data.frame()))
  draws <- do.call(rbind, draw_rows)
  write_bootstrap_checkpoint(sample_label, draws, reps)
  list(draws = draws, summary = summarize_bootstrap_draws(draws, reps))
}

run_bootstrap_all <- function(samples) {
  reps <- as.integer(cfg$bootstrap_reps)
  if (is.na(reps) || reps <= 0L) return(list(draws = data.frame(), summary = data.frame()))

  selected <- intersect(names(samples), cfg$bootstrap_samples)
  if (length(selected) == 0L) {
    log_msg("bootstrap skipped: none of BJS_BOOTSTRAP_SAMPLES matched constructed samples")
    return(list(draws = data.frame(), summary = data.frame()))
  }

  boot <- lapply(selected, function(nm) run_bootstrap_one(samples[[nm]], nm))
  list(
    draws = bind_nonempty(lapply(boot, `[[`, "draws")),
    summary = bind_nonempty(lapply(boot, `[[`, "summary"))
  )
}

write_inference_status <- function(boot) {
  bootstrap_available <- is.data.frame(boot$summary) && nrow(boot$summary) > 0L
  bootstrap_reps <- as.integer(cfg$bootstrap_reps)
  bootstrap_reps_paper_ready <- bootstrap_available && bootstrap_reps >= 499L
  status <- data.frame(
    bootstrap_reps_requested = bootstrap_reps,
    bootstrap_samples_requested = paste(cfg$bootstrap_samples, collapse = ","),
    bootstrap_available = bootstrap_available,
    bootstrap_reps_paper_ready = bootstrap_reps_paper_ready,
    paper_facing_inference_available = bootstrap_reps_paper_ready,
    naive_se_role = "descriptive diagnostics only",
    recommended_inference = if (bootstrap_available) {
      if (bootstrap_reps_paper_ready) {
        "Use bjs_bootstrap_summary.csv for reported estimands; report this as package-cluster bootstrap SE, not closed-form BJS conservative SE."
      } else {
        "Bootstrap output exists, but reps are below 499. Treat as exploratory; rerun with BJS_BOOTSTRAP_REPS=499 or 999 for paper-facing tables."
      }
    } else {
      "No paper-facing ATT inference produced. Re-run with BJS_BOOTSTRAP_REPS=499 or 999, or implement closed-form BJS conservative variance."
    },
    stringsAsFactors = FALSE
  )
  write_csv(status, file.path(out_dir, "bjs_inference_status.csv"))
}

make_plot <- function(event_all) {
  if (isTRUE(cfg$skip_plot)) {
    log_msg("plot skipped (CS2021_BJS_SKIP_PLOT=1)")
    return(invisible(NULL))
  }
  post_range <- event_all$event_time >= -12L & event_all$event_time <= cfg$event_max
  plot_df <- event_all[post_range, , drop = FALSE]
  if (nrow(plot_df) == 0L) return(invisible(NULL))

  p <- ggplot(plot_df, aes(x = event_time, y = att, color = sample, fill = sample)) +
    geom_hline(yintercept = 0, color = "grey65", linewidth = 0.4) +
    geom_vline(xintercept = 0, color = "grey65", linewidth = 0.4)

  if (isTRUE(cfg$plot_naive_bands)) {
    p <- p +
      geom_ribbon(aes(ymin = ci_low_naive, ymax = ci_high_naive), alpha = 0.12, color = NA)
  }

  subtitle <- if (isTRUE(cfg$plot_naive_bands)) {
    "Untreated outcome model: package FE + period FE. Bands use descriptive naive SEs, not final BJS inference."
  } else {
    "Untreated outcome model: package FE + period FE. Inference should be taken from bootstrap/conservative outputs, not naive bands."
  }

  p <- p +
    geom_line(linewidth = 0.9) +
    labs(
      title = "BJS-style imputation event-study estimates",
      subtitle = subtitle,
      x = "Event time",
      y = "Imputation residual ATT"
    ) +
    theme_minimal(base_size = 11) +
    theme(
      panel.grid.minor = element_blank(),
      legend.position = "bottom",
      legend.title = element_blank()
    )

  out_path <- file.path(out_dir, "bjs_dynamic_paths.png")
  ggsave(out_path, p, width = 9, height = 5.4, dpi = 220)
  log_msg("saved:", out_path)
}

main <- function() {
  if (file.exists(log_file)) file.remove(log_file)
  log_msg("START: BJS imputation v1")
  log_msg("panel_cache=", panel_cache_file)
  log_msg(sprintf("config: event_min=%d event_max=%d balanced=%s max_period=%d min_cohort_size=%d max_post_period=%d max_iter=%d tol=%g min_pre_obs=%d pretest_k=%d bootstrap_reps=%d bootstrap_samples=%s bootstrap_checkpoint_every=%d bootstrap_resume=%s sample_treated_n=%d sample_never_n=%d run_subgroup=%s run_sensitivity=%s run_pretrend_test=%s sensitivity_only=%s diag_only=%s plot_naive_bands=%s",
    cfg$event_min, cfg$event_max, paste(cfg$balanced_e_values, collapse = ","),
    cfg$max_period, cfg$min_cohort_size, cfg$max_post_period,
    cfg$max_iter, cfg$tol, cfg$min_pre_obs, cfg$pretest_k,
    cfg$bootstrap_reps, paste(cfg$bootstrap_samples, collapse = ","),
    cfg$bootstrap_checkpoint_every, ifelse(isTRUE(cfg$bootstrap_resume), "1", "0"),
    cfg$sample_treated_n, cfg$sample_never_n,
    ifelse(isTRUE(cfg$run_subgroup), "1", "0"),
    ifelse(isTRUE(cfg$run_sensitivity), "1", "0"),
    ifelse(isTRUE(cfg$run_pretrend_test), "1", "0"),
    ifelse(isTRUE(cfg$sensitivity_only), "1", "0"),
    ifelse(isTRUE(cfg$diag_only), "1", "0"),
    ifelse(isTRUE(cfg$plot_naive_bands), "1", "0")))
  write_config()

  if (!file.exists(panel_cache_file)) {
    stop("panel cache not found: ", panel_cache_file)
  }

  panel <- readRDS(panel_cache_file)
  panel <- normalize_panel(panel)
  panel <- apply_stability_filters(panel)
  panel <- sample_panel_for_debug(panel)
  write_timing_checks(panel)
  write_period_support(panel)

  base_diag <- data.frame(
    rows = nrow(panel),
    packages = length(unique(panel$package)),
    treated_packages = length(unique(panel$package[panel$G > 0L])),
    treated_packages_with_post = length(unique(panel$package[panel$post])),
    never_packages = length(unique(panel$package[panel$G == 0L])),
    min_period = min(panel$period, na.rm = TRUE),
    max_period = max(panel$period, na.rm = TRUE),
    min_G_treated = min(panel$G[panel$G > 0L], na.rm = TRUE),
    max_G_treated = max(panel$G[panel$G > 0L], na.rm = TRUE),
    official_before_yes_treated = length(unique(panel$package[panel$G > 0L & panel$official_before_event == 1L])),
    official_before_no_treated = length(unique(panel$package[panel$G > 0L & panel$official_before_event == 0L])),
    stringsAsFactors = FALSE
  )
  write_csv(base_diag, file.path(out_dir, "bjs_panel_definition_check.csv"))
  log_msg(sprintf("panel: rows=%d packages=%d treated=%d never=%d",
    base_diag$rows, base_diag$packages, base_diag$treated_packages, base_diag$never_packages))

  samples <- list()
  if (!isTRUE(cfg$sensitivity_only)) {
    samples$overall <- panel
    if (isTRUE(cfg$run_subgroup)) {
      samples$official_before_yes <- panel[panel$official_before_event == 1L, , drop = FALSE]
      samples$official_before_no <- panel[panel$official_before_event == 0L, , drop = FALSE]
    }
  } else {
    log_msg("main and standard subgroup skipped (CS2021_BJS_SENSITIVITY_ONLY=1)")
  }

  if (isTRUE(cfg$run_sensitivity)) {
    samples$gte13 <- panel[panel$G == 0L | panel$G >= 13L, , drop = FALSE]
    samples$glt12 <- panel[panel$G == 0L | (panel$G > 0L & panel$G < 12L), , drop = FALSE]
    samples$gte12 <- panel[panel$G == 0L | panel$G >= 12L, , drop = FALSE]
    panel_preobs <- add_pre_obs(panel)
    samples$preobs_ge12 <- panel_preobs[panel_preobs$G == 0L | panel_preobs$pre_obs >= 12L, , drop = FALSE]
    samples$preobs_ge12$pre_obs <- NULL
    if (isTRUE(cfg$run_subgroup)) {
      sub_yes <- panel[panel$official_before_event == 1L, , drop = FALSE]
      sub_no <- panel[panel$official_before_event == 0L, , drop = FALSE]
      samples$official_before_yes_gte13 <- sub_yes[sub_yes$G == 0L | sub_yes$G >= 13L, , drop = FALSE]
      samples$official_before_no_gte13 <- sub_no[sub_no$G == 0L | sub_no$G >= 13L, , drop = FALSE]
      sub_yes_preobs <- add_pre_obs(sub_yes)
      sub_no_preobs <- add_pre_obs(sub_no)
      samples$official_before_yes_preobs_ge12 <- sub_yes_preobs[sub_yes_preobs$G == 0L | sub_yes_preobs$pre_obs >= 12L, , drop = FALSE]
      samples$official_before_no_preobs_ge12 <- sub_no_preobs[sub_no_preobs$G == 0L | sub_no_preobs$pre_obs >= 12L, , drop = FALSE]
      samples$official_before_yes_preobs_ge12$pre_obs <- NULL
      samples$official_before_no_preobs_ge12$pre_obs <- NULL
    }
  } else {
    log_msg("sensitivity samples skipped (CS2021_BJS_RUN_SENSITIVITY=0)")
  }

  composition <- do.call(rbind, lapply(names(samples), function(nm) sample_composition(samples[[nm]], nm)))
  write_csv(composition, file.path(out_dir, "bjs_control_composition.csv"))

  results <- list()
  for (nm in names(samples)) {
    sample_df <- samples[[nm]]
    treated_n <- length(unique(sample_df$package[sample_df$G > 0L]))
    if (treated_n < 10L) {
      log_msg(sprintf("[%s] skipped: treated packages too few (%d)", nm, treated_n))
      next
    }
    if (isTRUE(cfg$diag_only)) {
      log_msg(sprintf("[%s] DIAG_ONLY=1: estimation skipped after sample construction", nm))
      next
    }
    results[[nm]] <- run_bjs_one(sample_df, tag = paste0("bjs_", nm), sample_label = nm)
    write_csv(results[[nm]]$event, file.path(out_dir, paste0("bjs_dynamic_", nm, ".csv")))
  }

  if (length(results) == 0L) {
    log_msg("no BJS estimation results produced")
    log_msg("DONE. output dir:", out_dir)
    return(invisible(NULL))
  }

  diagnostics_all <- do.call(rbind, lapply(results, `[[`, "diagnostics"))
  event_all <- do.call(rbind, lapply(results, `[[`, "event"))
  summary_all <- do.call(rbind, lapply(results, `[[`, "summary"))
  balanced_all <- do.call(rbind, lapply(results, `[[`, "balanced"))
  pretrend_summary_all <- bind_nonempty(lapply(results, `[[`, "pretrend_summary"))
  pretrend_coefficients_all <- bind_nonempty(lapply(results, `[[`, "pretrend_coefficients"))

  write_csv(diagnostics_all, file.path(out_dir, "bjs_diagnostics_summary.csv"))
  write_csv(event_all, file.path(out_dir, "bjs_dynamic_all.csv"))
  write_csv(summary_all, file.path(out_dir, "bjs_summary.csv"))
  write_csv(balanced_all, file.path(out_dir, "bjs_balanced_summary.csv"))
  if (!is.null(pretrend_summary_all) && nrow(pretrend_summary_all) > 0L) {
    write_csv(pretrend_summary_all, file.path(out_dir, "bjs_pretrend_test_summary.csv"))
  }
  if (!is.null(pretrend_coefficients_all) && nrow(pretrend_coefficients_all) > 0L) {
    write_csv(pretrend_coefficients_all, file.path(out_dir, "bjs_pretrend_test_coefficients.csv"))
  }

  boot <- run_bootstrap_all(samples)
  if (nrow(boot$draws) > 0L) {
    write_csv(boot$draws, file.path(out_dir, "bjs_bootstrap_draws.csv"))
  }
  if (nrow(boot$summary) > 0L) {
    write_csv(boot$summary, file.path(out_dir, "bjs_bootstrap_summary.csv"))
  }
  write_inference_status(boot)

  pre_diag <- event_all[event_all$event_time < 0L, , drop = FALSE]
  write_csv(pre_diag, file.path(out_dir, "bjs_pre_event_diagnostics.csv"))
  write_method_notes()
  make_plot(event_all)

  log_msg("DONE. output dir:", out_dir)
}

if (sys.nframe() == 0L) {
  main()
}
