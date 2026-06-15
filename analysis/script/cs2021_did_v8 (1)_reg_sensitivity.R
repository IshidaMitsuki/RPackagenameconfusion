# Callaway & SantAnna staggered DiD sensitivity script
# Auto-cleaned from parsed source to remove corrupted comments; executable code is preserved.

suppressPackageStartupMessages({
    library(did)
    library(jsonlite)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

args <- commandArgs(trailingOnly = FALSE)

file_arg <- grep("^--file=", args, value = TRUE)

script_path <- if (length(file_arg) > 0) {
    normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE)
} else NA_character_

base_dir <- if (!is.na(script_path) && nzchar(script_path)) dirname(script_path) else getwd()

project_dir <- normalizePath(file.path(base_dir, ".."), winslash = "/", mustWork = FALSE)

input_json <- file.path(project_dir, "overlay_data_2x3.json")

classified_csv <- file.path(project_dir, "output", "packages_classified_2x3.csv")

output_dir <- file.path(project_dir, "figures", "cs2021_did_r_v8")

if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

log_file <- file.path(output_dir, "run_progress.log")

panel_cache_file <- file.path(output_dir, "panel_cache_v8.rds")

debug_tag <- Sys.getenv("CS2021_DEBUG_TAG", "")

debug_output_dir <- if (nzchar(debug_tag)) {
    d <- file.path(output_dir, paste0("debug_", debug_tag))
    if (!dir.exists(d)) 
        dir.create(d, recursive = TRUE)
    d
} else {
    output_dir
}

log_msg <- function(...) {
    ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    msg <- paste0("[", ts, "] ", paste(..., collapse = " "))
    cat(msg, "\n")
    cat(msg, "\n", file = log_file, append = TRUE)
    flush.console()
}

get_env_flag <- function(name, default = FALSE) {
    v <- Sys.getenv(name, if (default) 
        "1"
    else "0")
    tolower(v) %in% c("1", "true", "yes", "y", "on")
}

get_env_int <- function(name, default = 0L) {
    v <- suppressWarnings(as.integer(Sys.getenv(name, as.character(default))))
    if (is.na(v)) 
        as.integer(default)
    else as.integer(v)
}

build_run_config <- function() {
    cfg <- list(est_method = "reg", force_control_group = "notyettreated", stage1_light_x = FALSE, stage2_x_mode = "pre3_slope", 
        stage2_one_step_fallback = FALSE, skip_control_selection_when_forced = TRUE, att_gt_print_details = FALSE, capture_att_gt_console = FALSE, 
        run_universal_ref = FALSE, use_panel_cache = TRUE, run_subgroup = TRUE, sample_treated_n = 0L, max_period = 120L, 
        min_cohort_size = 0L, max_post_period = 60L, dynamic_min_e = 0L, dynamic_max_e = 60L, balanced_e_values = c(12L, 
            24L, 36L, 48L), biters = 999L, subgroup_never_n = 0L, stage2_retry_faster_mode_on_mem = FALSE, memory_fallback_to_no_boot = FALSE, 
        diag_only = FALSE, skip_diagnostics = FALSE, run_sensitivity = FALSE, sensitivity_only = FALSE)
    cfg$skip_diagnostics <- get_env_flag("CS2021_SKIP_DIAGNOSTICS", default = cfg$skip_diagnostics)
    cfg$run_sensitivity <- get_env_flag("CS2021_RUN_SENSITIVITY", default = cfg$run_sensitivity)
    cfg$sensitivity_only <- get_env_flag("CS2021_SENSITIVITY_ONLY", default = cfg$sensitivity_only)
    if (isTRUE(cfg$sensitivity_only)) 
        cfg$run_sensitivity <- TRUE
    cfg
}

extract_att_df <- function(att_obj) {
    data.frame(group = att_obj$group, t = att_obj$t, att = att_obj$att, se = att_obj$se, stringsAsFactors = FALSE)
}

diagnose_att_obj <- function(att_obj, tag) {
    df <- extract_att_df(att_obj)
    n_total <- nrow(df)
    n_finite_att <- sum(is.finite(df$att))
    n_finite_se <- sum(is.finite(df$se))
    n_nonzero_att <- sum(is.finite(df$att) & abs(df$att) > 1e-12)
    log_msg(sprintf("[%s] diag: total=%d finite_att=%d finite_se=%d nonzero_att=%d", tag, n_total, n_finite_att, n_finite_se, 
        n_nonzero_att))
    list(total = n_total, finite_att = n_finite_att, finite_se = n_finite_se, nonzero_att = n_nonzero_att)
}

apply_stability_filters <- function(panel, min_cohort_size = 0L, max_post_period = -1L) {
    out <- panel
    if (min_cohort_size > 0L) {
        pkg_g <- unique(out[, c("package", "G")])
        treated <- pkg_g[pkg_g$G > 0L, ]
        if (nrow(treated) > 0L) {
            cohort_n <- aggregate(package ~ G, data = treated, FUN = length)
            names(cohort_n)[2] <- "n_pkg"
            keep_g <- cohort_n$G[cohort_n$n_pkg >= min_cohort_size]
            before_pkg <- length(unique(out$package[out$G > 0L]))
            out <- out[(out$G == 0L) | (out$G %in% keep_g), ]
            after_pkg <- length(unique(out$package[out$G > 0L]))
            log_msg(sprintf("stability filter: min_cohort_size=%d treated_packages %d -> %d", min_cohort_size, before_pkg, 
                after_pkg))
        }
    }
    if (max_post_period >= 0L) {
        before_rows <- nrow(out)
        out <- out[(out$G == 0L) | (out$period <= out$G + max_post_period), ]
        after_rows <- nrow(out)
        log_msg(sprintf("stability filter: max_post_period=%d rows %d -> %d", max_post_period, before_rows, after_rows))
    }
    out
}

run_identification_diagnostics <- function(panel, tag, control_group) {
    log_msg(sprintf("[%s] diagnostics: start (control_group=%s)", tag, control_group))
    id_col <- if ("package_id" %in% names(panel)) 
        "package_id"
    else "package"
    pkg_g <- unique(panel[, c(id_col, "G")])
    cohort_sz <- aggregate(pkg_g[[id_col]], by = list(G = pkg_g$G), FUN = length)
    names(cohort_sz)[2] <- "n_packages"
    write.csv(cohort_sz, file.path(output_dir, paste0("diagnostics_", tag, "_cohorts.csv")), row.names = FALSE)
    y_wide <- reshape(panel[, c(id_col, "period", "log_dl")], idvar = id_col, timevar = "period", direction = "wide")
    all_periods <- sort(unique(panel$period))
    treated_groups <- sort(unique(panel$G[panel$G > 0]))
    cells <- vector("list", length = 0L)
    k <- 0L
    for (gi in seq_along(treated_groups)) {
        g <- treated_groups[gi]
        base_p <- g - 1L
        if (!(base_p %in% all_periods)) 
            next
        base_col <- paste0("log_dl.", base_p)
        if (!(base_col %in% names(y_wide))) 
            next
        ts <- all_periods[all_periods >= g]
        for (t in ts) {
            t_col <- paste0("log_dl.", t)
            if (!(t_col %in% names(y_wide))) 
                next
            treat_idx <- pkg_g[[id_col]][pkg_g$G == g]
            if (control_group == "notyettreated") {
                ctrl_idx <- pkg_g[[id_col]][pkg_g$G == 0L | pkg_g$G > t]
            }
            else {
                ctrl_idx <- pkg_g[[id_col]][pkg_g$G == 0L]
            }
            treat_rows <- y_wide[[id_col]] %in% treat_idx
            ctrl_rows <- y_wide[[id_col]] %in% ctrl_idx
            d_treat <- y_wide[[t_col]][treat_rows] - y_wide[[base_col]][treat_rows]
            d_ctrl <- y_wide[[t_col]][ctrl_rows] - y_wide[[base_col]][ctrl_rows]
            n_treat <- length(d_treat)
            n_ctrl <- length(d_ctrl)
            n_treat_complete <- sum(is.finite(d_treat))
            n_ctrl_complete <- sum(is.finite(d_ctrl))
            var_treat <- suppressWarnings(stats::var(d_treat[is.finite(d_treat)]))
            var_ctrl <- suppressWarnings(stats::var(d_ctrl[is.finite(d_ctrl)]))
            k <- k + 1L
            cells[[k]] <- data.frame(g = g, t = t, base_period = base_p, n_treat = n_treat, n_ctrl = n_ctrl, n_treat_complete = n_treat_complete, 
                n_ctrl_complete = n_ctrl_complete, mean_delta_treat = mean(d_treat, na.rm = TRUE), mean_delta_ctrl = mean(d_ctrl, 
                  na.rm = TRUE), var_delta_treat = var_treat, var_delta_ctrl = var_ctrl, flag_no_treat = as.integer(n_treat == 
                  0L), flag_no_ctrl = as.integer(n_ctrl == 0L), flag_low_complete = as.integer(n_treat_complete < 5L | n_ctrl_complete < 
                  5L), flag_zero_var = as.integer((is.finite(var_treat) && var_treat <= .Machine$double.eps) | (is.finite(var_ctrl) && 
                  var_ctrl <= .Machine$double.eps)), stringsAsFactors = FALSE)
        }
        if (gi%%20L == 0L) {
            log_msg(sprintf("[%s] diagnostics: processed groups=%d/%d", tag, gi, length(treated_groups)))
        }
    }
    if (length(cells) == 0L) {
        log_msg(sprintf("[%s] diagnostics: no post-treatment cells", tag))
        return(invisible(NULL))
    }
    diag_df <- do.call(rbind, cells)
    out_csv <- file.path(output_dir, paste0("diagnostics_", tag, "_cells.csv"))
    write.csv(diag_df, out_csv, row.names = FALSE)
    n_cells <- nrow(diag_df)
    n_no_ctrl <- sum(diag_df$flag_no_ctrl == 1L)
    n_no_treat <- sum(diag_df$flag_no_treat == 1L)
    n_low <- sum(diag_df$flag_low_complete == 1L)
    n_zero_var <- sum(diag_df$flag_zero_var == 1L)
    log_msg(sprintf("[%s] diagnostics done: cells=%d no_ctrl=%d no_treat=%d low_complete=%d zero_var=%d", tag, n_cells, n_no_ctrl, 
        n_no_treat, n_low, n_zero_var))
    log_msg(sprintf("[%s] diagnostics saved: %s", tag, out_csv))
    invisible(diag_df)
}

to_date <- function(x) {
    x <- trimws(as.character(x))
    x[x %in% c("", "NA", "NaN", "NULL")] <- NA_character_
    out <- suppressWarnings(as.POSIXct(x, tz = "UTC", tryFormats = c("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%OS", 
        "%Y-%m-%d")))
    bad <- !is.na(x) & is.na(out)
    if (any(bad)) 
        out[bad] <- suppressWarnings(as.POSIXct(as.Date(x[bad]), tz = "UTC"))
    out
}

build_panel <- function() {
    log_msg("build_panel: start")
    cls <- read.csv(classified_csv, stringsAsFactors = FALSE)
    need_cols <- c("Package", "official_category", "timing_category", "first_nonofficial_date", "First_Download_Date")
    miss <- setdiff(need_cols, colnames(cls))
    if (length(miss) > 0) 
        stop(paste("packages_classified_2x3.csv missing required columns:", paste(miss, collapse = ", ")))
    cls$first_nonofficial_date <- to_date(cls$first_nonofficial_date)
    cls$First_Download_Date <- to_date(cls$First_Download_Date)
    if ("first_official_guidance_date" %in% names(cls)) {
        cls$first_official_guidance_date <- to_date(cls$first_official_guidance_date)
        has_guidance_date <- TRUE
    }
    else {
        cls$first_official_guidance_date <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
        has_guidance_date <- FALSE
        log_msg("build_panel: first_official_guidance_date not found; official_before_event falls back to official_category only")
    }
    calc_g <- function(first_non, first_dl) {
        if (is.na(first_non)) 
            return(0)
        if (is.na(first_dl)) 
            return(NA_real_)
        g <- floor(as.numeric(difftime(first_non, first_dl, units = "days"))/30)
        if (is.na(g) || g < 1) 
            return(NA_real_)
        g
    }
    cls$G <- mapply(calc_g, cls$first_nonofficial_date, cls$First_Download_Date)
    cls <- cls[!is.na(cls$G), ]
    cls$G <- as.numeric(cls$G)
    official_yes_marker <- intToUtf8(c(12354, 12426))
    cls$official <- as.integer(grepl(official_yes_marker, enc2utf8(cls$official_category), fixed = TRUE))
    cls$official_guidance_ever <- as.integer(!is.na(cls$first_official_guidance_date) | cls$official == 1L)
    cls$official_before_event <- as.integer(!is.na(cls$first_official_guidance_date) & (cls$G == 0L | cls$first_official_guidance_date < cls$first_nonofficial_date))
    cls$official_before_event[is.na(cls$official_before_event)] <- 0L
    if (!isTRUE(has_guidance_date)) {
        cls$official_before_event <- cls$official
    }
    cls$official_after_event <- as.integer(!is.na(cls$first_official_guidance_date) & cls$G > 0L & cls$first_official_guidance_date >= cls$first_nonofficial_date)
    cls$official_after_event[is.na(cls$official_after_event)] <- 0L
    log_msg(sprintf("build_panel: official guidance ever=%d before_event=%d after_event=%d",
        sum(cls$official_guidance_ever == 1L, na.rm = TRUE),
        sum(cls$official_before_event == 1L, na.rm = TRUE),
        sum(cls$official_after_event == 1L, na.rm = TRUE)))
    raw <- fromJSON(input_json, simplifyVector = FALSE)
    info <- cls[, c("Package", "G", "official", "official_guidance_ever", "official_before_event", "official_after_event", "timing_category")]
    rownames(info) <- info$Package
    rows <- list()
    idx <- 1L
    pkg_seen <- 0L
    rec_seen <- 0L
    cat_total <- length(names(raw))
    cat_i <- 0L
    last_hb <- Sys.time()
    for (cat_key in names(raw)) {
        cat_i <- cat_i + 1L
        pkgs <- raw[[cat_key]]
        log_msg(sprintf("build_panel: category %d/%d (%s), packages=%d", cat_i, cat_total, cat_key, length(pkgs)))
        for (pkg in names(pkgs)) {
            pkg_seen <- pkg_seen + 1L
            if (!pkg %in% rownames(info)) 
                next
            recs <- pkgs[[pkg]]
            if (length(recs) == 0) 
                next
            for (rec in recs) {
                rec_seen <- rec_seen + 1L
                rows[[idx]] <- data.frame(package = pkg, period = as.integer(rec$period), downloads = as.numeric(rec$Downloads %||% 
                  0), G = as.numeric(info[pkg, "G"]), official = as.integer(info[pkg, "official"]),
                  official_guidance_ever = as.integer(info[pkg, "official_guidance_ever"]),
                  official_before_event = as.integer(info[pkg, "official_before_event"]),
                  official_after_event = as.integer(info[pkg, "official_after_event"]),
                  timing_cat = as.character(info[pkg, "timing_category"]), stringsAsFactors = FALSE)
                idx <- idx + 1L
                if (rec_seen%%200000L == 0L) {
                  log_msg(sprintf("build_panel: records=%d, rows=%d, packages_seen=%d", rec_seen, idx - 1L, pkg_seen))
                }
                now <- Sys.time()
                if (as.numeric(difftime(now, last_hb, units = "secs")) >= 20) {
                  log_msg(sprintf("build_panel: heartbeat packages_seen=%d records=%d rows=%d", pkg_seen, rec_seen, idx - 
                    1L))
                  last_hb <- now
                }
            }
            if (pkg_seen%%2000L == 0L) {
                log_msg(sprintf("build_panel: packages_seen=%d, records=%d", pkg_seen, rec_seen))
            }
        }
    }
    panel <- unique(do.call(rbind, rows))
    global_t_max <- max(panel$period, na.rm = TRUE)
    panel <- panel[(panel$G == 0L) | (panel$G <= global_t_max), ]
    max_per <- aggregate(period ~ package, data = panel, FUN = max)
    names(max_per)[2] <- "period_max"
    panel <- merge(panel, max_per, by = "package", all.x = TRUE)
    panel <- panel[(panel$G == 0L) | (panel$G <= panel$period_max), ]
    panel$period_max <- NULL
    panel$log_dl <- log1p(panel$downloads)
    panel$age_at_event <- ifelse(panel$G > 0L, panel$G, 0L)
    treated <- panel[panel$G > 0, ]
    treated$rel <- treated$period - treated$G
    pre3_t <- aggregate(log_dl ~ package, data = treated[treated$rel >= -3 & treated$rel < 0, ], FUN = mean)
    names(pre3_t)[2] <- "log_dl_pre3"
    pre3_n <- aggregate(log_dl ~ package, data = panel[panel$G == 0, ], FUN = mean)
    names(pre3_n)[2] <- "log_dl_pre3"
    pre3 <- rbind(pre3_t, pre3_n)
    panel <- merge(panel, pre3, by = "package", all.x = TRUE)
    panel$log_dl_pre3[is.na(panel$log_dl_pre3)] <- median(panel$log_dl_pre3, na.rm = TRUE)
    pre12_t <- aggregate(log_dl ~ package, data = treated[treated$rel >= -12 & treated$rel < 0, ], FUN = mean)
    names(pre12_t)[2] <- "log_dl_pre12"
    pre12_n <- aggregate(log_dl ~ package, data = panel[panel$G == 0, ], FUN = mean)
    names(pre12_n)[2] <- "log_dl_pre12"
    pre12 <- rbind(pre12_t, pre12_n)
    panel <- merge(panel, pre12, by = "package", all.x = TRUE)
    panel$log_dl_pre12[is.na(panel$log_dl_pre12)] <- median(panel$log_dl_pre12, na.rm = TRUE)
    baseline <- panel[order(panel$package, panel$period), ]
    baseline$obs_rank <- ave(baseline$period, baseline$package, FUN = seq_along)
    baseline_pre12 <- baseline[baseline$obs_rank <= 12, c("package", "period", "log_dl")]
    baseline_mean <- aggregate(log_dl ~ package, data = baseline_pre12, FUN = mean)
    names(baseline_mean)[2] <- "baseline_log_dl_12"
    baseline_slope <- aggregate(cbind(log_dl, period) ~ package, data = baseline_pre12, FUN = function(z) z)
    baseline_slope$baseline_slope_12 <- vapply(seq_len(nrow(baseline_slope)), function(i) {
        y <- baseline_slope$log_dl[[i]]
        x <- baseline_slope$period[[i]]
        if (length(y) < 3 || length(unique(x)) < 2) 
            return(NA_real_)
        coef(lm(y ~ x))[2]
    }, numeric(1))
    baseline_slope <- baseline_slope[, c("package", "baseline_slope_12")]
    panel <- merge(panel, baseline_mean, by = "package", all.x = TRUE)
    panel <- merge(panel, baseline_slope, by = "package", all.x = TRUE)
    panel$baseline_log_dl_12[is.na(panel$baseline_log_dl_12)] <- median(panel$baseline_log_dl_12, na.rm = TRUE)
    panel$baseline_slope_12[is.na(panel$baseline_slope_12)] <- median(panel$baseline_slope_12, na.rm = TRUE)
    slope_t <- aggregate(cbind(log_dl, period) ~ package, data = treated[treated$rel >= -12 & treated$rel < 0, ], FUN = function(z) z)
    slope_t$pretrend_slope <- vapply(seq_len(nrow(slope_t)), function(i) {
        y <- slope_t$log_dl[[i]]
        x <- slope_t$period[[i]]
        if (length(y) < 3 || length(unique(x)) < 2) 
            return(NA_real_)
        coef(lm(y ~ x))[2]
    }, numeric(1))
    slope_t <- slope_t[, c("package", "pretrend_slope")]
    never <- panel[panel$G == 0, ]
    never <- never[order(never$package, never$period), ]
    never$obs_rank <- ave(never$period, never$package, FUN = seq_along)
    never_pre <- never[never$obs_rank <= 12, c("package", "period", "log_dl")]
    slope_n <- aggregate(cbind(log_dl, period) ~ package, data = never_pre, FUN = function(z) z)
    slope_n$pretrend_slope <- vapply(seq_len(nrow(slope_n)), function(i) {
        y <- slope_n$log_dl[[i]]
        x <- slope_n$period[[i]]
        if (length(y) < 3 || length(unique(x)) < 2) 
            return(NA_real_)
        coef(lm(y ~ x))[2]
    }, numeric(1))
    slope_n <- slope_n[, c("package", "pretrend_slope")]
    slope_df <- rbind(slope_t, slope_n)
    panel <- merge(panel, slope_df, by = "package", all.x = TRUE)
    panel$pretrend_slope[is.na(panel$pretrend_slope)] <- median(panel$pretrend_slope, na.rm = TRUE)
    keep_cols <- c("package", "period", "G", "official", "official_guidance_ever", "official_before_event", "official_after_event", "log_dl", "age_at_event", "log_dl_pre3", "log_dl_pre12", "pretrend_slope", 
        "baseline_log_dl_12", "baseline_slope_12")
    panel <- panel[, keep_cols, drop = FALSE]
    panel$package <- as.factor(panel$package)
    log_msg("build_panel: done", paste0("rows=", nrow(panel)), paste0("packages=", length(unique(panel$package))), paste0("treated_packages=", 
        length(unique(panel$package[panel$G > 0]))), paste0("never_packages=", length(unique(panel$package[panel$G == 0]))), 
        paste0("n_cohorts=", length(unique(panel$G[panel$G > 0]))))
    panel
}

panel_checks <- function(panel) {
    stopifnot("package_id" %in% colnames(panel))
    dup_n <- sum(duplicated(panel[, c("package_id", "period")]))
    log_msg("check: duplicated (package_id, period)=", dup_n)
    if (dup_n > 0) 
        stop("duplicate (package_id, period) rows found")
    g_by_pkg <- aggregate(G ~ package_id, data = panel, FUN = function(v) length(unique(v)))
    if (any(g_by_pkg$G != 1L)) {
        stop("G varies within at least one package_id")
    }
    period_range <- range(panel$period, na.rm = TRUE)
    g_pos <- panel$G[panel$G > 0]
    log_msg("check:", paste0("period_range=", period_range[1], "..", period_range[2]), paste0("G_range=", min(g_pos), "..", 
        max(g_pos)))
    cohort_sz <- aggregate(package_id ~ G, data = unique(panel[, c("package_id", "G")]), FUN = length)
    names(cohort_sz)[2] <- "n_pkg"
    write.csv(cohort_sz, file.path(output_dir, "cohort_sizes.csv"), row.names = FALSE)
    log_msg("check: cohort size table saved")
    invisible(cohort_sz)
}

run_att_gt <- function(panel, control_group, biters, bstrap, cband, base_period, tag, est_method = "dr", xformla = ~official_before_event + 
    log_dl_pre3 + pretrend_slope, xformla_label = "official_before_event + log_dl_pre3 + pretrend_slope", print_details = FALSE, capture_att_gt_console = FALSE, 
    faster_mode = FALSE) {
    log_msg("att_gt start:", paste0("tag=", tag), paste0("control_group=", control_group), paste0("est_method=", est_method), 
        paste0("xformla=", xformla_label), paste0("faster_mode=", ifelse(isTRUE(faster_mode), "1", "0")), paste0("print_details=", 
            ifelse(isTRUE(print_details), "1", "0")), paste0("base_period=", base_period), paste0("bstrap=", bstrap), paste0("biters=", 
            biters))
    t0 <- Sys.time()
    if (isTRUE(capture_att_gt_console)) {
        sink(log_file, append = TRUE, split = TRUE)
        on.exit(sink(), add = TRUE)
    }
    need_cols <- unique(c("log_dl", "period", "package_id", "G", all.vars(xformla)))
    miss_cols <- setdiff(need_cols, names(panel))
    if (length(miss_cols) > 0L) {
        stop(sprintf("att_gt input missing columns: %s", paste(miss_cols, collapse = ", ")))
    }
    att_input <- panel[, need_cols, drop = FALSE]
    on.exit({
        rm(att_input)
        invisible(gc(verbose = FALSE))
    }, add = TRUE)
    fit <- att_gt(yname = "log_dl", tname = "period", idname = "package_id", gname = "G", xformla = xformla, data = att_input, 
        est_method = est_method, control_group = control_group, bstrap = bstrap, biters = biters, cband = cband, anticipation = 0, 
        panel = TRUE, allow_unbalanced_panel = TRUE, faster_mode = isTRUE(faster_mode), base_period = base_period, print_details = isTRUE(print_details))
    elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
    log_msg("att_gt done:", paste0("tag=", tag), paste0("elapsed_sec=", elapsed))
    fit
}

pretrend_report <- function(att_fit, tag) {
    if (is.null(att_fit$att) || is.null(att_fit$se)) {
        log_msg("pretrend: no ATT(g,t) data for tag=", tag)
        return(invisible(NULL))
    }
    df <- data.frame(group = att_fit$group, t = att_fit$t, att = att_fit$att, se = att_fit$se)
    df$rel <- df$t - df$group
    pre <- df[df$rel < 0 & is.finite(df$att) & is.finite(df$se) & df$se > 0, ]
    if (nrow(pre) == 0L) {
        log_msg("pretrend: pre-trend period not found for tag=", tag)
        return(invisible(NULL))
    }
    pre$z <- pre$att/pre$se
    pre$p <- 2 * (1 - pnorm(abs(pre$z)))
    sig_n <- sum(pre$p < 0.05, na.rm = TRUE)
    chi2 <- sum(pre$z^2, na.rm = TRUE)
    df_ <- sum(!is.na(pre$z))
    p_wald <- 1 - pchisq(chi2, df = df_)
    log_msg(sprintf("[%s] Pre-trend: cells=%d pointwise_p_lt_0.05=%d Wald_chi2(%d)=%.2f p=%.4f", tag, nrow(pre), sig_n, df_, 
        chi2, p_wald))
    out <- data.frame(group = pre$group, t = pre$t, rel = pre$rel, att = pre$att, se = pre$se, z = pre$z, p = pre$p)
    write.csv(out, file.path(output_dir, paste0("pretrend_", tag, ".csv")), row.names = FALSE)
    invisible(out)
}

balanced_aggte <- function(att_fit, e0 = 12, biters = 999, tag = "") {
    tryCatch({
        bal <- aggte(att_fit, type = "dynamic", balance_e = e0, min_e = 0, max_e = e0, bstrap = TRUE, biters = biters, cband = TRUE, 
            na.rm = TRUE)
        log_msg(sprintf("[%s] balanced dynamic: e0=%d, ATT=%.4f SE=%.4f", tag, e0, bal$overall.att, bal$overall.se))
        bal
    }, error = function(e) {
        log_msg(sprintf("[%s] balanced dynamic failed (e0=%d): %s", tag, e0, conditionMessage(e)))
        NULL
    })
}

run_pipeline <- function(panel, tag, run_config) {
    biters <- as.integer(run_config$biters)
    if (is.na(biters) || biters < 0L) 
        biters <- 999L
    drop_constant_terms <- function(formula, data, label) {
        term_labels <- attr(terms(formula), "term.labels")
        if (length(term_labels) == 0L) 
            return(list(formula = formula, label = label))
        keep_terms <- vapply(term_labels, function(term) {
            if (!term %in% names(data)) 
                return(TRUE)
            values <- data[[term]]
            values <- values[is.finite(values)]
            length(unique(values)) > 1L
        }, logical(1))
        kept_labels <- term_labels[keep_terms]
        if (length(kept_labels) == 0L) 
            return(list(formula = ~1, label = "1"))
        new_formula <- as.formula(paste("~", paste(kept_labels, collapse = " + ")))
        new_label <- paste(kept_labels, collapse = " + ")
        if (!identical(new_label, label)) {
            log_msg(sprintf("[%s] constant covariates dropped: %s -> %s", tag, label, new_label))
        }
        list(formula = new_formula, label = new_label)
    }
    panel$package_id <- as.integer(factor(panel$package))
    panel_checks(panel)
    if ("package" %in% names(panel)) 
        panel$package <- NULL
    if (isTRUE(run_config$diag_only)) {
        log_msg(sprintf("[%s] DIAG_ONLY=1", tag))
        diag_nyt <- run_identification_diagnostics(panel, paste0(tag, "_notyettreated"), "notyettreated")
        diag_nev <- run_identification_diagnostics(panel, paste0(tag, "_nevertreated"), "nevertreated")
        return(invisible(list(diagnostics_notyettreated = diag_nyt, diagnostics_nevertreated = diag_nev)))
    }
    est_main <- tolower(run_config$est_method)
    if (!est_main %in% c("dr", "reg", "ipw")) 
        est_main <- "dr"
    stage2_mode <- tolower(run_config$stage2_x_mode)
    if (identical(stage2_mode, "pre12")) {
        xformla <- ~official_before_event + log_dl_pre12
        x_label <- "official_before_event + log_dl_pre12"
    }
    else {
        xformla <- ~official_before_event + log_dl_pre3 + pretrend_slope
        x_label <- "official_before_event + log_dl_pre3 + pretrend_slope"
    }
    x_info <- drop_constant_terms(xformla, panel, x_label)
    xformla <- x_info$formula
    x_label <- x_info$label
    control_group <- run_config$force_control_group
    if (is.null(control_group) || is.na(control_group) || !nzchar(control_group)) {
        control_group <- "notyettreated"
    }
    if (!isTRUE(run_config$skip_diagnostics)) {
        run_identification_diagnostics(panel, paste0(tag, "_", control_group), control_group)
    }
    bstrap <- TRUE
    cband <- TRUE
    base_period <- run_config$base_period %||% "varying"
    if (length(base_period) == 0L || is.na(base_period) || !nzchar(base_period)) 
        base_period <- "varying"
    att_main <- run_att_gt(panel = panel, control_group = control_group, biters = biters, bstrap = bstrap, cband = cband, 
        base_period = base_period, tag = tag, est_method = est_main, xformla = xformla, xformla_label = x_label, print_details = isTRUE(run_config$att_gt_print_details), 
        capture_att_gt_console = isTRUE(run_config$capture_att_gt_console), faster_mode = isTRUE(run_config$faster_mode))
    diagnose_att_obj(att_main, tag)
    pretrend_report(att_main, tag = tag)
    dyn_min <- as.integer(run_config$dynamic_min_e)
    dyn_max <- as.integer(run_config$dynamic_max_e)
    if (is.na(dyn_min)) 
        dyn_min <- 0L
    if (is.na(dyn_max)) 
        dyn_max <- 60L
    dyn <- aggte(att_main, type = "dynamic", min_e = dyn_min, max_e = dyn_max, bstrap = bstrap, biters = biters, cband = cband, 
        na.rm = TRUE)
    grp <- aggte(att_main, type = "group", bstrap = bstrap, biters = biters, cband = cband, na.rm = TRUE)
    cal <- aggte(att_main, type = "calendar", bstrap = bstrap, biters = biters, cband = cband, na.rm = TRUE)
    capture.output(summary(att_main), file = file.path(output_dir, paste0(tag, "_att_gt_summary.txt")))
    capture.output(summary(dyn), file = file.path(output_dir, paste0(tag, "_dynamic_summary.txt")))
    capture.output(summary(grp), file = file.path(output_dir, paste0(tag, "_group_summary.txt")))
    capture.output(summary(cal), file = file.path(output_dir, paste0(tag, "_calendar_summary.txt")))
    balanced <- list()
    for (e0 in as.integer(run_config$balanced_e_values)) {
        if (is.na(e0)) 
            next
        balanced[[paste0("e", e0)]] <- balanced_aggte(att_main, e0 = e0, biters = biters, tag = tag)
        if (!is.null(balanced[[paste0("e", e0)]])) {
            capture.output(summary(balanced[[paste0("e", e0)]]), file = file.path(output_dir, paste0(tag, "_dynamic_balanced_e", 
                e0, "_summary.txt")))
        }
    }
    list(att_gt = att_main, dynamic = dyn, group = grp, calendar = cal, balanced = balanced)
}

run_subgroup <- function(panel_full, run_config) {
    log_msg("STEP 7: official-before-event yes/no subgroup estimation")
    results <- list()
    subgroup_never_n <- as.integer(run_config$subgroup_never_n)
    if (is.na(subgroup_never_n) || subgroup_never_n < 0L) 
        subgroup_never_n <- 0L
    for (off_val in c(1L, 0L)) {
        label <- if (off_val == 1L) 
            "official_before_yes"
        else "official_before_no"
        log_msg(sprintf("[subgroup] %s (official_before_event=%d)", label, off_val))
        sub <- panel_full[panel_full$official_before_event == off_val, ]
        if (subgroup_never_n > 0L) {
            never_pkgs <- unique(sub$package[sub$G == 0L])
            if (length(never_pkgs) > subgroup_never_n) {
                set.seed(42 + off_val)
                keep_never <- sample(never_pkgs, subgroup_never_n)
                treat_pkgs <- unique(sub$package[sub$G > 0L])
                sub <- sub[sub$package %in% c(treat_pkgs, keep_never), ]
                log_msg(sprintf("[subgroup] %s: sampled never-treated to %d", label, length(keep_never)))
            }
        }
        n_treat <- length(unique(sub$package[sub$G > 0]))
        if (n_treat < 10L) {
            log_msg(sprintf("[subgroup] %s skipped: treated packages too few (%d)", label, n_treat))
            next
        }
        cfg <- run_config
        results[[label]] <- run_pipeline(sub, tag = label, run_config = cfg)
    }
    invisible(results)
}

run_sensitivity <- function(panel_full, run_config) {
    log_msg("STEP 8: sensitivity specifications")
    results <- list()
    run_one <- function(sub, tag, cfg) {
        n_treat <- length(unique(sub$package[sub$G > 0L]))
        if (n_treat < 10L) {
            log_msg(sprintf("[sensitivity] %s skipped: treated packages too few (n=%d)", tag, n_treat))
            return(NULL)
        }
        tryCatch(run_pipeline(sub, tag = tag, run_config = cfg), error = function(e) {
            log_msg(sprintf("[sensitivity] %s failed: %s", tag, conditionMessage(e)))
            NULL
        })
    }
    cfg_never <- run_config
    cfg_never$force_control_group <- "nevertreated"
    cfg_never$skip_control_selection_when_forced <- TRUE
    results[["sens_never"]] <- run_one(panel_full, "sens_never", cfg_never)
    cfg_pre12 <- run_config
    cfg_pre12$stage2_x_mode <- "pre12"
    sub_pre12 <- panel_full[(panel_full$G == 0L) | (panel_full$G >= 13L), ]
    results[["sens_gte13_pre12"]] <- run_one(sub_pre12, "sens_gte13_pre12", cfg_pre12)
    sub_early <- panel_full[(panel_full$G == 0L) | (panel_full$G < 12L), ]
    results[["sens_early_glt12"]] <- run_one(sub_early, "sens_early_glt12", run_config)
    sub_late <- panel_full[(panel_full$G == 0L) | (panel_full$G >= 12L), ]
    results[["sens_late_gte12"]] <- run_one(sub_late, "sens_late_gte12", run_config)
    for (off_val in c(1L, 0L)) {
        off_label <- if (off_val == 1L) 
            "official_before_yes"
        else "official_before_no"
        sub_off <- panel_full[panel_full$official_before_event == off_val, ]
        cfg_off_never <- run_config
        cfg_off_never$force_control_group <- "nevertreated"
        cfg_off_never$skip_control_selection_when_forced <- TRUE
        tag_never <- paste0("sens_", off_label, "_never")
        results[[tag_never]] <- run_one(sub_off, tag_never, cfg_off_never)
        cfg_off_pre12 <- run_config
        cfg_off_pre12$stage2_x_mode <- "pre12"
        sub_off_pre12 <- sub_off[(sub_off$G == 0L) | (sub_off$G >= 13L), ]
        tag_pre12 <- paste0("sens_", off_label, "_gte13_pre12")
        results[[tag_pre12]] <- run_one(sub_off_pre12, tag_pre12, cfg_off_pre12)
    }
    invisible(results)
}

main <- function() {
    if (file.exists(log_file)) 
        file.remove(log_file)
    log_msg("START: CS2021 DID v8")
    log_msg("input_json=", input_json)
    log_msg("classified_csv=", classified_csv)
    log_msg("output_dir=", output_dir)
    run_config <- build_run_config()
    log_msg("run profile: final-primary defaults")
    log_msg(sprintf("config: est_method=%s force_control_group=%s stage2_x_mode=%s run_subgroup=%s biters=%d", run_config$est_method, 
        run_config$force_control_group, run_config$stage2_x_mode, ifelse(isTRUE(run_config$run_subgroup), "1", "0"), as.integer(run_config$biters)))
    log_msg(sprintf("config: sample_treated_n=%d max_period=%d min_cohort_size=%d max_post_period=%d use_panel_cache=%s", 
        as.integer(run_config$sample_treated_n), as.integer(run_config$max_period), as.integer(run_config$min_cohort_size), 
        as.integer(run_config$max_post_period), ifelse(isTRUE(run_config$use_panel_cache), "1", "0")))
    log_msg(sprintf("config(change-candidate): diag_only=%s skip_diagnostics=%s", ifelse(isTRUE(run_config$diag_only), "1", 
        "0"), ifelse(isTRUE(run_config$skip_diagnostics), "1", "0")))
    log_msg(sprintf("config(lighten): skip_control_selection_when_forced=%s att_gt_print_details=%s capture_att_gt_console=%s", 
        ifelse(isTRUE(run_config$skip_control_selection_when_forced), "1", "0"), ifelse(isTRUE(run_config$att_gt_print_details), 
            "1", "0"), ifelse(isTRUE(run_config$capture_att_gt_console), "1", "0")))
    use_cache <- isTRUE(run_config$use_panel_cache)
    run_subgroup_flag <- isTRUE(run_config$run_subgroup)
    run_sensitivity_flag <- isTRUE(run_config$run_sensitivity)
    sensitivity_only_flag <- isTRUE(run_config$sensitivity_only)
    panel <- NULL
    if (use_cache && file.exists(panel_cache_file)) {
        cache_mtime <- file.info(panel_cache_file)$mtime
        in1_mtime <- file.info(input_json)$mtime
        in2_mtime <- file.info(classified_csv)$mtime
        if (!is.na(cache_mtime) && !is.na(in1_mtime) && !is.na(in2_mtime) && cache_mtime >= in1_mtime && cache_mtime >= in2_mtime) {
            log_msg("panel cache hit: ", panel_cache_file)
            panel <- readRDS(panel_cache_file)
        }
        else {
            log_msg("panel cache is stale vs input data; rebuild required")
        }
    }
    if (is.null(panel)) {
        panel <- build_panel()
        if (use_cache) {
            saveRDS(panel, panel_cache_file)
            log_msg("panel cache saved: ", panel_cache_file)
        }
    }
    if ("G" %in% names(panel)) {
        if (is.integer(panel$G) || !is.numeric(panel$G)) {
            panel$G <- as.numeric(panel$G)
            log_msg("panel normalize: coerced G to double")
        }
    }
    if ("period" %in% names(panel) && min(panel$period, na.rm = TRUE) == 0) {
        treated_idx <- panel$G > 0
        panel$G[treated_idx] <- as.integer(panel$G[treated_idx]) + 1L
        panel$age_at_event[treated_idx] <- as.integer(panel$age_at_event[treated_idx]) + 1L
        log_msg("panel normalize: shifted period/G/age_at_event to 1-based index for did")
    }
    max_period <- as.integer(run_config$max_period)
    min_cohort_size <- as.integer(run_config$min_cohort_size)
    max_post_period <- as.integer(run_config$max_post_period)
    sample_treated_n <- as.integer(run_config$sample_treated_n)
    if (is.na(sample_treated_n) || sample_treated_n < 0L) 
        sample_treated_n <- 0L
    if (sample_treated_n > 0L) {
        set.seed(42)
        treated_pkgs <- unique(panel$package[panel$G > 0L])
        if (length(treated_pkgs) > sample_treated_n) {
            keep_treated <- sample(treated_pkgs, sample_treated_n)
            keep_never <- unique(panel$package[panel$G == 0L])
            keep_pkgs <- c(keep_treated, keep_never)
            panel <- panel[panel$package %in% keep_pkgs, ]
            log_msg("sample option: sample_treated_n=", sample_treated_n, " applied; kept treated packages=", length(keep_treated))
        }
        else {
            log_msg("sample option: sample_treated_n ignored (treated <= sample size)")
        }
    }
    if (max_period >= 0L) {
        panel <- panel[panel$period <= max_period, ]
        log_msg("sample option: max_period=", max_period, " applied")
    }
    panel <- apply_stability_filters(panel, min_cohort_size = min_cohort_size, max_post_period = max_post_period)
    log_msg(sprintf("Panel: rows=%d, packages=%d", nrow(panel), length(unique(panel$package))))
    biters <- as.integer(run_config$biters)
    if (is.na(biters) || biters < 0) 
        biters <- 999L
    log_msg("biters=", biters)
    run_config$biters <- biters
    if (sensitivity_only_flag) {
        log_msg("STEP 2-7: main and standard subgroup analyses skipped (CS2021_SENSITIVITY_ONLY=1)")
    }
    else {
        log_msg("STEP 2-6: overall estimation")
        res_all <- run_pipeline(panel, tag = "overall", run_config = run_config)
        if (run_subgroup_flag) {
            log_msg("STEP 7: standard official-before-event yes/no subgroup estimation")
            run_subgroup(panel, run_config = run_config)
        }
        else {
            log_msg("STEP 7: standard subgroup estimation skipped (run_subgroup=0)")
        }
    }
    if (run_sensitivity_flag) {
        run_sensitivity(panel, run_config = run_config)
    }
    else {
        log_msg("STEP 8: sensitivity specifications skipped (CS2021_RUN_SENSITIVITY=0)")
    }
    log_msg(sprintf("DONE. output dir: %s", output_dir))
}

if (sys.nframe() == 0) {
    main()
}

