# ===========================================================================
# Callaway & Sant'Anna (2021) Staggered DiD  ── R 実装 v8
# ===========================================================================
#
# v8 での主変更点:
#   [Lock-1] 主推定 est_method を DR に固定（既定）
#   [Lock-2] 識別診断を既定ON（skip_diagnostics=FALSE）
#   [Lock-3] サブグループ推定のサンプル定義を main 方針と整合
#            （official 層内で treated/never/not-yet を構成）
#   [Lock-4] v8 専用の出力先/キャッシュを使用
#
# v7 での修正点 (v6 からの変更):
#   [Fix-1] faster_mode=FALSE を att_gt 呼び出しに追加 (重大)
#           did::att_gt の正式引数。ログに "Try changing faster_mode=FALSE"
#           と出ていた通り、これなしで notyettreated が失敗するケースがある。
#   [Fix-2] ログ文言を est_method に合わせて動的化 (中)
#           "main dr failed" → paste0("main ", est_main, " failed")
#   [Fix-3] デバッグ用 output_dir を本番と分離 (中)
#           CS2021_DEBUG_TAG 環境変数でサブディレクトリを切る
#   [Fix-4] aggte に na.rm=TRUE を追加 (中)
#           ATT(g,t) に NA セルが残る場合に aggte が落ちる経路を塞ぐ
#
# v7 運用時の追加アレンジ (最小変更ポリシー):
#   [Adj-1] Stage1 のみ軽量共変量を許可 (run_config$stage1_light_x)
#           既定: FALSE。TRUE の場合は Stage1 で ~ official + log_dl_pre3 を使う。
#   [Adj-2] Stage2 は full 式を第一優先にし、失敗時のみ 1段 fallback を許可
#           (run_config$stage2_one_step_fallback)
#           既定: FALSE。TRUE の場合、full 失敗時に
#           ~ official + log_dl_pre3 で 1 回だけ再試行する。
#           ログに full 失敗と fallback 採用を必ず残す。
#
# 研究の識別戦略:
#   イベント    : CRANパッケージと同名の非公式 GitHub repo の初出現
#   処理群      : 「後から同名あり」(CRAN公開後に初の同名repoが作成されたパッケージ)
#   対照群      : never-treated(同名なし) + not-yet-treated
#   結果変数    : log(月次DL数 + 1)
#   サブグループ: 公式誘導あり vs なし  ← 主張Bの拡張検証
#
# v2 での修正点 (sample.R からの変更):
#   [Fix-1] G <= 0 の除外バグ修正: g <= 0L → g < 1L
#           (G=1 = CRAN公開翌月に同名repo出現 を誤って除外していた)
#   [Fix-2] panel_checks の package_id 依存を明示化
#           (run_did で付与後に呼ぶ順序を保証)
#   [Fix-3] base_period = "universal" を追加し "varying" と比較
#           (pre-trend の解釈を論文設定に合わせる)
#   [Add-1] サブグループ分析 (公式誘導あり / なし) の実装
#           主張B: 公式誘導あり群で post 効果がより大きいか
#   [Add-2] θ^{bal}_{es} 相当の集計 (aggte min_e/max_e で近似)
#           構成変化バイアスを除去した動態効果の報告
#   [Add-3] pre-trend 検定の自動レポート
#   [Add-4] 推定失敗時のフォールバックを整理
#
# 参照:
#   Callaway & Sant'Anna (2021), J. Econometrics 225(2), 200-230
#   https://doi.org/10.1016/j.jeconom.2020.12.001
#   did パッケージ: https://bcallaway11.github.io/did/
# ===========================================================================

suppressPackageStartupMessages({
  library(did)
  library(jsonlite)
})

# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
`%||%` <- function(a, b) if (!is.null(a)) a else b

# スクリプトパス解決 (Rscript --file= 経由でも source() でも動く)
args      <- commandArgs(trailingOnly = FALSE)
file_arg  <- grep("^--file=", args, value = TRUE)
script_path <- if (length(file_arg) > 0) {
  normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE)
} else NA_character_
base_dir  <- if (!is.na(script_path) && nzchar(script_path)) dirname(script_path) else getwd()

project_dir   <- normalizePath(file.path(base_dir, ".."), winslash = "/", mustWork = FALSE)
input_json    <- file.path(project_dir, "overlay_data_2x3.json")
classified_csv <- file.path(project_dir, "output", "packages_classified_2x3.csv")
output_dir    <- file.path(project_dir, "figures", "cs2021_did_r_v8")
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
log_file      <- file.path(output_dir, "run_progress.log")
panel_cache_file <- file.path(output_dir, "panel_cache_v8.rds")

# デバッグ実行用に出力先を分離する [Fix-3]
# CS2021_DEBUG_TAG=short などを設定すると output_dir/debug_short/ に書き出す
debug_tag <- Sys.getenv("CS2021_DEBUG_TAG", "")
debug_output_dir <- if (nzchar(debug_tag)) {
  d <- file.path(output_dir, paste0("debug_", debug_tag))
  if (!dir.exists(d)) dir.create(d, recursive = TRUE)
  d
} else {
  output_dir
}

log_msg <- function(...) {
  ts  <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  msg <- paste0("[", ts, "] ", paste(..., collapse = " "))
  cat(msg, "\n"); cat(msg, "\n", file = log_file, append = TRUE)
  flush.console()
}

get_env_flag <- function(name, default = FALSE) {
  v <- Sys.getenv(name, if (default) "1" else "0")
  tolower(v) %in% c("1", "true", "yes", "y", "on")
}

get_env_int <- function(name, default = 0L) {
  v <- suppressWarnings(as.integer(Sys.getenv(name, as.character(default))))
  if (is.na(v)) as.integer(default) else as.integer(v)
}

# ---------------------------------------------------------------------------
# 本番推定の固定設定（デフォルト）
#   - Rscript 単体実行で本推定が走るよう、識別仕様をここで固定する。
#   - 環境変数は「変更可能性が高い運用トグル」のみに限定する。
# ---------------------------------------------------------------------------
build_run_config <- function() {
  cfg <- list(
    est_method = "dr",
    force_control_group = "notyettreated",
    stage1_light_x = FALSE,
    stage2_x_mode = "full",
    stage2_one_step_fallback = FALSE,
    skip_control_selection_when_forced = TRUE,
    att_gt_print_details = FALSE,
    capture_att_gt_console = FALSE,
    run_universal_ref = FALSE,
    use_panel_cache = TRUE,
    run_subgroup = FALSE,
    sample_treated_n = 0L,
    max_period = 120L,
    min_cohort_size = 0L,
    max_post_period = 60L,
    biters = 999L,
    subgroup_never_n = 0L,
    stage2_retry_faster_mode_on_mem = FALSE,
    memory_fallback_to_no_boot = FALSE,
    # 変更候補（運用で切替える可能性がある箇所）
    # - diag_only: 推定を回さず診断CSVのみ出力する
    # - skip_diagnostics: 本推定時の診断CSV生成を省略してメモリ負荷を下げる
    # - att_gt_print_details/capture_att_gt_console: 実行ログ量の制御
    diag_only = FALSE,
    skip_diagnostics = FALSE
  )

  # 変更候補のみ環境変数上書きを許可（他はコード固定）
  cfg$diag_only <- get_env_flag("CS2021_DIAG_ONLY", default = cfg$diag_only)
  cfg$skip_diagnostics <- get_env_flag("CS2021_SKIP_DIAGNOSTICS", default = cfg$skip_diagnostics)

  cfg
}

extract_att_df <- function(att_obj) {
  data.frame(
    group = att_obj$group,
    t = att_obj$t,
    att = att_obj$att,
    se = att_obj$se,
    stringsAsFactors = FALSE
  )
}

diagnose_att_obj <- function(att_obj, tag) {
  df <- extract_att_df(att_obj)
  n_total <- nrow(df)
  n_finite_att <- sum(is.finite(df$att))
  n_finite_se <- sum(is.finite(df$se))
  n_nonzero_att <- sum(is.finite(df$att) & abs(df$att) > 1e-12)
  log_msg(sprintf("[%s] diag: total=%d finite_att=%d finite_se=%d nonzero_att=%d",
                  tag, n_total, n_finite_att, n_finite_se, n_nonzero_att))
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
      log_msg(sprintf("stability filter: min_cohort_size=%d treated_packages %d -> %d",
                      min_cohort_size, before_pkg, after_pkg))
    }
  }

  if (max_post_period >= 0L) {
    before_rows <- nrow(out)
    out <- out[(out$G == 0L) | (out$period <= out$G + max_post_period), ]
    after_rows <- nrow(out)
    log_msg(sprintf("stability filter: max_post_period=%d rows %d -> %d",
                    max_post_period, before_rows, after_rows))
  }

  out
}

run_identification_diagnostics <- function(panel, tag, control_group) {
  log_msg(sprintf("[%s] diagnostics: start (control_group=%s)", tag, control_group))

  id_col <- if ("package_id" %in% names(panel)) "package_id" else "package"

  pkg_g <- unique(panel[, c(id_col, "G")])
  cohort_sz <- aggregate(pkg_g[[id_col]], by = list(G = pkg_g$G), FUN = length)
  names(cohort_sz)[2] <- "n_packages"
  write.csv(cohort_sz,
            file.path(output_dir, paste0("diagnostics_", tag, "_cohorts.csv")),
            row.names = FALSE)

  y_wide <- reshape(
    panel[, c(id_col, "period", "log_dl")],
    idvar = id_col,
    timevar = "period",
    direction = "wide"
  )

  all_periods <- sort(unique(panel$period))
  treated_groups <- sort(unique(panel$G[panel$G > 0]))
  cells <- vector("list", length = 0L)
  k <- 0L

  for (gi in seq_along(treated_groups)) {
    g <- treated_groups[gi]
    base_p <- g - 1L
    if (!(base_p %in% all_periods)) next

    base_col <- paste0("log_dl.", base_p)
    if (!(base_col %in% names(y_wide))) next

    ts <- all_periods[all_periods >= g]
    for (t in ts) {
      t_col <- paste0("log_dl.", t)
      if (!(t_col %in% names(y_wide))) next

      treat_idx <- pkg_g[[id_col]][pkg_g$G == g]
      if (control_group == "notyettreated") {
        ctrl_idx <- pkg_g[[id_col]][pkg_g$G == 0L | pkg_g$G > t]
      } else {
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
      cells[[k]] <- data.frame(
        g = g,
        t = t,
        base_period = base_p,
        n_treat = n_treat,
        n_ctrl = n_ctrl,
        n_treat_complete = n_treat_complete,
        n_ctrl_complete = n_ctrl_complete,
        mean_delta_treat = mean(d_treat, na.rm = TRUE),
        mean_delta_ctrl = mean(d_ctrl, na.rm = TRUE),
        var_delta_treat = var_treat,
        var_delta_ctrl = var_ctrl,
        flag_no_treat = as.integer(n_treat == 0L),
        flag_no_ctrl = as.integer(n_ctrl == 0L),
        flag_low_complete = as.integer(n_treat_complete < 5L | n_ctrl_complete < 5L),
        flag_zero_var = as.integer((is.finite(var_treat) && var_treat <= .Machine$double.eps) |
                                     (is.finite(var_ctrl) && var_ctrl <= .Machine$double.eps)),
        stringsAsFactors = FALSE
      )
    }
    if (gi %% 20L == 0L) {
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

  log_msg(sprintf("[%s] diagnostics done: cells=%d no_ctrl=%d no_treat=%d low_complete=%d zero_var=%d",
                  tag, n_cells, n_no_ctrl, n_no_treat, n_low, n_zero_var))
  log_msg(sprintf("[%s] diagnostics saved: %s", tag, out_csv))

  invisible(diag_df)
}

to_date <- function(x) {
  x <- trimws(as.character(x))
  x[x %in% c("", "NA", "NaN", "NULL")] <- NA_character_
  out <- suppressWarnings(as.POSIXct(
    x, tz = "UTC",
    tryFormats = c("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
                   "%Y-%m-%dT%H:%M:%OS", "%Y-%m-%d")
  ))
  bad <- !is.na(x) & is.na(out)
  if (any(bad)) out[bad] <- suppressWarnings(as.POSIXct(as.Date(x[bad]), tz = "UTC"))
  out
}

# ---------------------------------------------------------------------------
# STEP 1: パネルデータ構築
# ---------------------------------------------------------------------------
build_panel <- function() {
  log_msg("build_panel: start")

  cls <- read.csv(classified_csv, stringsAsFactors = FALSE)
  need_cols <- c("Package", "official_category", "timing_category",
                 "first_nonofficial_date", "First_Download_Date")
  miss <- setdiff(need_cols, colnames(cls))
  if (length(miss) > 0) stop(paste("packages_classified_2x3.csv に必要列が不足:", paste(miss, collapse = ", ")))

  cls$first_nonofficial_date <- to_date(cls$first_nonofficial_date)
  cls$First_Download_Date    <- to_date(cls$First_Download_Date)

  # ------------------------------------------------------------------
  # G の計算  [Fix-1]
  #   never-treated (同名なし)  : G = 0  (CS2021 の慣例)
  #   treated (後から同名あり)  : G = floor(diff_days / 30)
  #   既に同名あり              : NA → 除外 (always-treated は対照群にも
  #                                         処理群にもなれない; CS2021 p.5 脚注3)
  #
  # [Fix-1] 旧: g <= 0L を除外 → G=1 (公開翌月に同名repo出現) も落ちていた
  #         新: g < 1L を除外  → G=1 は有効な treated コホートとして残す
  # ------------------------------------------------------------------
  calc_g <- function(timing, first_non, first_dl) {
    if (timing == "後から同名あり") {
      if (is.na(first_non) || is.na(first_dl)) return(NA_real_)
      g <- floor(as.numeric(difftime(first_non, first_dl, units = "days")) / 30)
      if (is.na(g) || g < 1) return(NA_real_)   # [Fix-1] <= 0 → < 1
      return(g)
    }
    if (timing == "同名なし") return(0)
    NA_integer_   # 既に同名あり → 除外
  }

  cls$G       <- mapply(calc_g, cls$timing_category,
                        cls$first_nonofficial_date, cls$First_Download_Date)
  cls         <- cls[!is.na(cls$G), ]
  cls$G       <- as.numeric(cls$G)
  cls$official <- as.integer(cls$official_category == "公式へ誘導あり")

  # 時系列 JSON 読み込み
  raw  <- fromJSON(input_json, simplifyVector = FALSE)
  info <- cls[, c("Package", "G", "official", "timing_category")]
  rownames(info) <- info$Package

  rows <- list(); idx <- 1L
  pkg_seen <- 0L
  rec_seen <- 0L
  cat_total <- length(names(raw))
  cat_i <- 0L
  last_hb <- Sys.time()
  for (cat_key in names(raw)) {
    cat_i <- cat_i + 1L
    pkgs <- raw[[cat_key]]
    log_msg(sprintf("build_panel: category %d/%d (%s), packages=%d",
                    cat_i, cat_total, cat_key, length(pkgs)))
    for (pkg in names(pkgs)) {
      pkg_seen <- pkg_seen + 1L
      if (!pkg %in% rownames(info)) next
      recs <- pkgs[[pkg]]
      if (length(recs) == 0) next
      for (rec in recs) {
        rec_seen <- rec_seen + 1L
        rows[[idx]] <- data.frame(
          package    = pkg,
          period     = as.integer(rec$period),
          downloads  = as.numeric(rec$Downloads %||% 0),
          G          = as.numeric(info[pkg, "G"]),
          official   = as.integer(info[pkg, "official"]),
          timing_cat = as.character(info[pkg, "timing_category"]),
          stringsAsFactors = FALSE
        )
        idx <- idx + 1L
        if (rec_seen %% 200000L == 0L) {
          log_msg(sprintf("build_panel: records=%d, rows=%d, packages_seen=%d",
                          rec_seen, idx - 1L, pkg_seen))
        }
        now <- Sys.time()
        if (as.numeric(difftime(now, last_hb, units = "secs")) >= 20) {
          log_msg(sprintf("build_panel: heartbeat packages_seen=%d records=%d rows=%d",
                          pkg_seen, rec_seen, idx - 1L))
          last_hb <- now
        }
      }
      if (pkg_seen %% 2000L == 0L) {
        log_msg(sprintf("build_panel: packages_seen=%d, records=%d",
                        pkg_seen, rec_seen))
      }
    }
  }

  panel <- unique(do.call(rbind, rows))

  # 処理後期間が1期以上観測されるコホートのみ残す
  global_t_max <- max(panel$period, na.rm = TRUE)
  panel        <- panel[(panel$G == 0L) | (panel$G <= global_t_max), ]
  max_per      <- aggregate(period ~ package, data = panel, FUN = max)
  names(max_per)[2] <- "period_max"
  panel        <- merge(panel, max_per, by = "package", all.x = TRUE)
  panel        <- panel[(panel$G == 0L) | (panel$G <= panel$period_max), ]
  panel$period_max <- NULL

  # 結果変数
  panel$log_dl <- log1p(panel$downloads)

  # 共変量1: イベント時のパッケージ月齢
  panel$age_at_event <- ifelse(panel$G > 0L, panel$G, 0L)

  # 共変量2: イベント直前3期の平均 log_dl  (論文: 条件付き PT の共変量)
  treated   <- panel[panel$G > 0, ]
  treated$rel <- treated$period - treated$G
  pre3_t    <- aggregate(log_dl ~ package,
                         data = treated[treated$rel >= -3 & treated$rel < 0, ],
                         FUN = mean)
  names(pre3_t)[2] <- "log_dl_pre3"

  pre3_n <- aggregate(log_dl ~ package,
                      data = panel[panel$G == 0, ],
                      FUN = mean)
  names(pre3_n)[2] <- "log_dl_pre3"

  pre3  <- rbind(pre3_t, pre3_n)
  panel <- merge(panel, pre3, by = "package", all.x = TRUE)
  panel$log_dl_pre3[is.na(panel$log_dl_pre3)] <- median(panel$log_dl_pre3, na.rm = TRUE)

  # 共変量3: イベント直前12期の平均 log_dl
  pre12_t <- aggregate(log_dl ~ package,
                       data = treated[treated$rel >= -12 & treated$rel < 0, ],
                       FUN = mean)
  names(pre12_t)[2] <- "log_dl_pre12"

  pre12_n <- aggregate(log_dl ~ package,
                       data = panel[panel$G == 0, ],
                       FUN = mean)
  names(pre12_n)[2] <- "log_dl_pre12"

  pre12 <- rbind(pre12_t, pre12_n)
  panel <- merge(panel, pre12, by = "package", all.x = TRUE)
  panel$log_dl_pre12[is.na(panel$log_dl_pre12)] <- median(panel$log_dl_pre12, na.rm = TRUE)

  # 共変量4: 処理前トレンドの傾き（treated/neverで12期窓を対称化）
  slope_t <- aggregate(cbind(log_dl, period) ~ package,
                       data = treated[treated$rel >= -12 & treated$rel < 0, ],
                       FUN = function(z) z)
  slope_t$pretrend_slope <- vapply(seq_len(nrow(slope_t)), function(i) {
    y <- slope_t$log_dl[[i]]
    x <- slope_t$period[[i]]
    if (length(y) < 3 || length(unique(x)) < 2) return(NA_real_)
    coef(lm(y ~ x))[2]
  }, numeric(1))
  slope_t <- slope_t[, c("package", "pretrend_slope")]

  never <- panel[panel$G == 0, ]
  never <- never[order(never$package, never$period), ]
  # never-treated は各パッケージの観測先頭12期を「処理前窓」に対応させる
  never$obs_rank <- ave(never$period, never$package, FUN = seq_along)
  never_pre <- never[never$obs_rank <= 12, c("package", "period", "log_dl")]

  slope_n <- aggregate(cbind(log_dl, period) ~ package,
                       data = never_pre,
                       FUN = function(z) z)
  slope_n$pretrend_slope <- vapply(seq_len(nrow(slope_n)), function(i) {
    y <- slope_n$log_dl[[i]]
    x <- slope_n$period[[i]]
    if (length(y) < 3 || length(unique(x)) < 2) return(NA_real_)
    coef(lm(y ~ x))[2]
  }, numeric(1))
  slope_n <- slope_n[, c("package", "pretrend_slope")]

  slope_df <- rbind(slope_t, slope_n)
  panel <- merge(panel, slope_df, by = "package", all.x = TRUE)
  panel$pretrend_slope[is.na(panel$pretrend_slope)] <- median(panel$pretrend_slope, na.rm = TRUE)

  # 主推定で使わない列はここで削除し、メモリ圧迫を抑える
  keep_cols <- c("package", "period", "G", "official", "log_dl",
                 "age_at_event", "log_dl_pre3", "log_dl_pre12", "pretrend_slope")
  panel <- panel[, keep_cols, drop = FALSE]
  panel$package <- as.factor(panel$package)

  log_msg("build_panel: done",
          paste0("rows=",               nrow(panel)),
          paste0("packages=",           length(unique(panel$package))),
          paste0("treated_packages=",   length(unique(panel$package[panel$G > 0]))),
          paste0("never_packages=",     length(unique(panel$package[panel$G == 0]))),
          paste0("n_cohorts=",          length(unique(panel$G[panel$G > 0]))))
  panel
}

# ---------------------------------------------------------------------------
# STEP 2: パネル整合性チェック  [Fix-2]
#   panel_checks は run_did 内で package_id 付与後に呼ぶ。
#   関数内では package_id 列の存在を明示的に確認する。
# ---------------------------------------------------------------------------
panel_checks <- function(panel) {
  stopifnot("package_id 列が必要です" = "package_id" %in% colnames(panel))

  dup_n <- sum(duplicated(panel[, c("package_id", "period")]))
  log_msg("check: duplicated (package_id, period)=", dup_n)
  if (dup_n > 0) stop("重複する (package_id, period) が存在します")

  g_by_pkg <- aggregate(G ~ package_id, data = panel,
                        FUN = function(v) length(unique(v)))
  if (any(g_by_pkg$G != 1L))
    stop("同一 package_id で複数の G が存在します")

  period_range <- range(panel$period, na.rm = TRUE)
  g_pos        <- panel$G[panel$G > 0]
  log_msg("check:",
          paste0("period_range=", period_range[1], "..", period_range[2]),
          paste0("G_range=",      min(g_pos),      "..", max(g_pos)))

  cohort_sz <- aggregate(package_id ~ G,
                         data = unique(panel[, c("package_id", "G")]),
                         FUN  = length)
  names(cohort_sz)[2] <- "n_pkg"
  write.csv(cohort_sz, file.path(output_dir, "cohort_sizes.csv"), row.names = FALSE)
  log_msg("check: cohort size table saved")
  invisible(cohort_sz)
}

# ---------------------------------------------------------------------------
# STEP 3: att_gt ラッパー
# ---------------------------------------------------------------------------
run_att_gt <- function(panel, control_group, biters, bstrap, cband,
       base_period, tag, est_method = "dr",
       xformla = ~ official + age_at_event + log_dl_pre3,
       xformla_label = "official + age_at_event + log_dl_pre3",
       print_details = FALSE,
     capture_att_gt_console = FALSE,
     faster_mode = FALSE) {
  log_msg("att_gt start:", paste0("tag=", tag),
          paste0("control_group=", control_group),
      paste0("est_method=", est_method),
      paste0("xformla=", xformla_label),
    paste0("faster_mode=", ifelse(isTRUE(faster_mode), "1", "0")),
      paste0("print_details=", ifelse(isTRUE(print_details), "1", "0")),
          paste0("base_period=",   base_period),
          paste0("bstrap=", bstrap), paste0("biters=", biters))
  t0 <- Sys.time()

  # did の詳細出力はログ肥大とI/O負荷が大きいため既定では抑制する。
  # 必要時のみ capture_att_gt_console=TRUE で att_gt のコンソール出力を記録する。
  if (isTRUE(capture_att_gt_console)) {
    sink(log_file, append = TRUE, split = TRUE)
    on.exit(sink(), add = TRUE)
  }

  # att_gt に渡す列を最小化し、不要列コピーによるメモリ圧迫を避ける
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

  fit <- att_gt(
    yname       = "log_dl",
    tname       = "period",
    idname      = "package_id",
    gname       = "G",
    xformla     = xformla,
    data        = att_input,
    est_method  = est_method,
    control_group = control_group,
    bstrap      = bstrap,
    biters      = biters,
    cband       = cband,
    anticipation = 0,
    panel       = TRUE,
    allow_unbalanced_panel = TRUE,
    faster_mode = isTRUE(faster_mode),
    base_period = base_period,
    print_details = isTRUE(print_details)
  )

  elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
  log_msg("att_gt done:", paste0("tag=", tag), paste0("elapsed_sec=", elapsed))
  fit
}

# ---------------------------------------------------------------------------
# STEP 4: pre-trend 検定レポート  [Add-3]
#   rel < 0 の ATT(g,t) が全体として 0 かを確認。
#   Roth (2022): 「棄却できない ≠ 仮定成立」を明記。
# ---------------------------------------------------------------------------
pretrend_report <- function(att_fit, tag) {
  df  <- extract_att_df(att_fit)
  if (is.null(df) || nrow(df) == 0) {
    log_msg("pretrend: no ATT(g,t) data for tag=", tag); return(invisible(NULL))
  }

  # did の出力列名差分に備える
  g_col <- if ("group" %in% names(df)) "group" else if ("g" %in% names(df)) "g" else NA_character_
  t_col <- if ("t" %in% names(df)) "t" else if ("year" %in% names(df)) "year" else NA_character_
  if (is.na(g_col) || is.na(t_col)) {
    log_msg("pretrend: group/time 列を特定できないためスキップ: ", paste(names(df), collapse = ","))
    return(invisible(NULL))
  }

  # 各行の rel = t - g を計算
  df$rel  <- df[[t_col]] - df[[g_col]]
  pre     <- df[df$rel < 0 & !is.na(df$att) & !is.na(df$se), ]

  if (nrow(pre) == 0) {
    log_msg("pretrend: pre-trend period not found for tag=", tag); return(invisible(NULL))
  }

  pre$z <- pre$att / pre$se
  pre$p <- 2 * (1 - pnorm(abs(pre$z)))
  sig_n <- sum(pre$p < 0.05, na.rm = TRUE)

  # Wald 同時検定 (H0: 全 pre ATT = 0)
  chi2   <- sum(pre$z^2, na.rm = TRUE)
  df_    <- sum(!is.na(pre$z))
  p_wald <- 1 - pchisq(chi2, df = df_)

  log_msg(sprintf("[%s] Pre-trend: %d 期間中 pointwise 有意=%d, Wald χ²(%d)=%.2f p=%.4f",
                  tag, nrow(pre), sig_n, df_, chi2, p_wald))
  if (sig_n == 0 && p_wald > 0.05) {
    log_msg(sprintf("[%s] → Pre-trend の証拠なし (平行トレンド仮定を棄却できない)", tag))
  } else {
    log_msg(sprintf("[%s] → 警告: pre-trend 検出。共変量を追加するか解釈に注意", tag))
  }
  log_msg("※ Roth(2022): 棄却できない ≠ 仮定成立 に注意")

  out <- data.frame(
    group = pre[[g_col]],
    t = pre[[t_col]],
    rel = pre$rel,
    att = pre$att,
    se = pre$se,
    z = pre$z,
    p = pre$p
  )
  write.csv(out, file.path(output_dir, paste0("pretrend_", tag, ".csv")),
            row.names = FALSE)
  invisible(out)
}

# ---------------------------------------------------------------------------
# STEP 5: θ^{bal}_{es} 相当の集計  [Add-2]
#   did::aggte の min_e / max_e 引数で
#   「e0 期間以上観測されるコホートのみ使う」バランス補正に近似する。
#
#   θ^{bal}_{es}(e; e0) = Σ_g 1{g+e0≤T} * P(G=g|G+e0≤T) * ATT(g, g+e)
#   → aggte(type="dynamic", min_e=-K, max_e=e0) で e<=e0 に絞ることで
#     コホート構成が変化しない範囲の集計を得る (CS2021 eq.3.6 の精神)
# ---------------------------------------------------------------------------
balanced_aggte <- function(att_fit, e0 = 12, biters = 999, tag = "") {
  tryCatch({
    bal <- aggte(att_fit, type = "dynamic",
                 min_e = -e0, max_e = e0,
                 bstrap = TRUE, biters = biters, cband = TRUE,
                 na.rm = TRUE)   # [Fix-4]
    log_msg(sprintf("[%s] θ^bal_es: e0=%d, ATT=%.4f SE=%.4f",
                    tag, e0,
                    bal$overall.att, bal$overall.se))
    bal
  }, error = function(e) {
    log_msg(sprintf("[%s] θ^bal_es failed (e0=%d): %s", tag, e0, conditionMessage(e)))
    NULL
  })
}

# ---------------------------------------------------------------------------
# STEP 6: 1つの対象グループに対するフル推定パイプライン
#   (全体 / 公式誘導あり / 公式誘導なし で共通して呼ぶ)
#
#   base_period の選択について:
#     "varying"   : 各コホート g のベースライン = g-1 (処理直前期)
#                   CS(2021) Theorem 1 の識別の標準形。
#                   did パッケージのデフォルト。これを主推定に使う。
#     "universal" : 全コホート共通のベースライン = min(G)-1
#                   pre-trend プロットの見た目が揃うが、
#                   コホートが多く G の range が広い場合に推定が退化し
#                   ATT が全ゼロになる既知の問題がある。参考用のみ。
# ---------------------------------------------------------------------------
run_pipeline <- function(panel, tag, run_config) {

  biters <- as.integer(run_config$biters)
  if (is.na(biters) || biters < 0L) biters <- 999L

  # --- 6a: package_id 付与 & チェック ---
  panel$package_id <- as.integer(factor(panel$package))
  panel_checks(panel)

  # 重い推定の前に文字列ラベル列を落として連続メモリ確保を助ける
  if ("package" %in% names(panel)) {
    panel$package <- NULL
    invisible(gc(verbose = FALSE))
  }

  if (isTRUE(run_config$diag_only)) {
    log_msg(sprintf("[%s] DIAG_ONLY=1: 推定を行わず診断のみ実行", tag))
    diag_nyt <- run_identification_diagnostics(panel, paste0(tag, "_notyettreated"), "notyettreated")
    diag_nev <- run_identification_diagnostics(panel, paste0(tag, "_nevertreated"), "nevertreated")
    return(invisible(list(
      diagnostics_notyettreated = diag_nyt,
      diagnostics_nevertreated = diag_nev
    )))
  }

  est_main <- tolower(run_config$est_method)
  if (!est_main %in% c("dr", "reg", "ipw")) est_main <- "dr"

  # Stage1（推定可能性チェック）だけを軽量式に切り替えるオプション。
  # Stage2 の本推定式は run_config$stage2_x_mode で選択する。
  stage1_light_x <- isTRUE(run_config$stage1_light_x)
  if (stage1_light_x) {
    stage1_xformla <- ~ official + log_dl_pre3
    stage1_x_label <- "official + log_dl_pre3"
  } else {
    stage1_xformla <- ~ official + age_at_event + log_dl_pre3
    stage1_x_label <- "official + age_at_event + log_dl_pre3"
  }
  log_msg(sprintf("[%s] Stage1 xformla: %s", tag, stage1_x_label))

  stage2_x_mode <- tolower(run_config$stage2_x_mode)
  if (!stage2_x_mode %in% c("full", "no_age", "pre12", "pre3_slope", "nogx")) stage2_x_mode <- "full"
  if (stage2_x_mode == "no_age") {
    stage2_full_xformla <- ~ official + log_dl_pre3
    stage2_full_x_label <- "official + log_dl_pre3"
  } else if (stage2_x_mode == "pre12") {
    stage2_full_xformla <- ~ official + log_dl_pre12
    stage2_full_x_label <- "official + log_dl_pre12"
  } else if (stage2_x_mode == "pre3_slope") {
    stage2_full_xformla <- ~ official + log_dl_pre3 + pretrend_slope
    stage2_full_x_label <- "official + log_dl_pre3 + pretrend_slope"
  } else if (stage2_x_mode == "nogx") {
    stage2_full_xformla <- ~ 1
    stage2_full_x_label <- "1"
  } else {
    stage2_full_xformla <- ~ official + age_at_event + log_dl_pre3
    stage2_full_x_label <- "official + age_at_event + log_dl_pre3"
  }

  stage2_fb_xformla <- ~ official + log_dl_pre3
  stage2_fb_x_label <- "official + log_dl_pre3"
  stage2_one_step_fallback <- isTRUE(run_config$stage2_one_step_fallback)
  if (stage2_x_mode %in% c("no_age", "pre12", "pre3_slope", "nogx")) stage2_one_step_fallback <- FALSE
  log_msg(sprintf("[%s] Stage2 xformla mode: %s", tag, stage2_x_mode))

  att_gt_print_details <- isTRUE(run_config$att_gt_print_details)
  capture_att_gt_console <- isTRUE(run_config$capture_att_gt_console)
  if (att_gt_print_details && !capture_att_gt_console) {
    capture_att_gt_console <- TRUE
  }

  forced_ctrl <- tolower(run_config$force_control_group)
  can_force <- forced_ctrl %in% c("notyettreated", "nevertreated")
  skip_stage1_ctrl_select <- isTRUE(run_config$skip_control_selection_when_forced) && can_force

  # --- 6b: 対照群の選択（高速・bootstrap なし） ---
  # エラー有無だけでなく推定品質（nonzero_att）も確認する [指摘2 対応]
  # 強制対照群が指定されている本番運用では、Stage1探索を省略してメモリ消費を抑える。
  log_msg(sprintf("[%s] Stage1: 対照群の選択 (est_method=%s)", tag, est_main))

  is_viable <- function(fit_obj) {
    if (is.null(fit_obj)) return(FALSE)
    d <- diagnose_att_obj(fit_obj, paste0(tag, "_feascheck"))
    d$nonzero_att > 0   # finite かつ 非ゼロのセルが1つ以上あるか
  }

  core_notyet <- NULL
  core_never <- NULL
  if (skip_stage1_ctrl_select) {
    ctrl_grp <- forced_ctrl
    log_msg(sprintf("[%s] Stage1省略: 強制対照群を採用 (%s)", tag, ctrl_grp))
  } else {
    core_notyet <- tryCatch(
      run_att_gt(panel, control_group = "notyettreated",
                 biters = 0, bstrap = FALSE, cband = FALSE,
                 base_period = "varying", tag = paste0(tag, "_core_notyet"),
                 est_method = est_main,
                 xformla = stage1_xformla,
                 xformla_label = stage1_x_label,
                 print_details = att_gt_print_details,
                 capture_att_gt_console = capture_att_gt_console),
      error = function(e) {
        log_msg(sprintf("[%s] notyettreated failed: %s", tag, conditionMessage(e))); NULL
      }
    )

    ctrl_grp <- if (is_viable(core_notyet)) {
      "notyettreated"
    } else {
      if (!is.null(core_notyet))
        log_msg(sprintf("[%s] notyettreated は推定できたが退化 → nevertreated を試行", tag))
      else
        log_msg(sprintf("[%s] notyettreated エラー → nevertreated を試行", tag))

      core_never <- tryCatch(
        run_att_gt(panel, control_group = "nevertreated",
                   biters = 0, bstrap = FALSE, cband = FALSE,
                   base_period = "varying", tag = paste0(tag, "_core_never"),
                   est_method = est_main,
                   xformla = stage1_xformla,
                   xformla_label = stage1_x_label,
                   print_details = att_gt_print_details,
                   capture_att_gt_console = capture_att_gt_console),
        error = function(e) {
          log_msg(sprintf("[%s] nevertreated also failed: %s", tag, conditionMessage(e))); NULL
        }
      )
      if (is_viable(core_never)) "nevertreated" else NULL
    }

    if (can_force) {
      ctrl_grp <- forced_ctrl
      log_msg(sprintf("[%s] 対照群を強制指定: %s", tag, forced_ctrl))
    }
  }

  if (is.null(ctrl_grp)) {
    log_msg(sprintf("[%s] 推定不可: スキップ", tag))
    return(invisible(NULL))
  }
  log_msg(sprintf("[%s] 対照群: %s", tag, ctrl_grp))

  # Stage1 で使用した中間オブジェクトを明示解放
  if (exists("core_notyet", inherits = FALSE)) rm(core_notyet)
  if (exists("core_never", inherits = FALSE)) rm(core_never)
  invisible(gc(verbose = FALSE))

  skip_diagnostics <- isTRUE(run_config$skip_diagnostics)
  if (skip_diagnostics) {
    log_msg(sprintf("[%s] diagnostics skipped (CS2021_SKIP_DIAGNOSTICS=1)", tag))
    diag_df <- NULL
  } else {
    diag_df <- run_identification_diagnostics(panel, tag, ctrl_grp)
  }

  # diagnostics は以降で使わないため、主推定前に解放
  diag_df <- NULL
  invisible(gc(verbose = FALSE))

  # --- 6c: 主推定 base_period = "varying" (CS2021 Theorem 1 の標準形) ---
  log_msg(sprintf("[%s] Stage2: 主推定 (base_period=varying, est_method=%s)", tag, est_main))
  stage2_used_fallback <- FALSE
  stage2_used_fastmem_fallback <- FALSE
  stage2_used_memory_fallback <- FALSE
  stage2_main_err <- NULL
  att_main <- tryCatch(
    run_att_gt(panel, control_group = ctrl_grp,
               biters = biters, bstrap = TRUE, cband = TRUE,
               base_period = "varying", tag = paste0(tag, "_main"),
               est_method = est_main,
               xformla = stage2_full_xformla,
               xformla_label = stage2_full_x_label,
               print_details = att_gt_print_details,
               capture_att_gt_console = capture_att_gt_console,
               faster_mode = FALSE),
    error = function(e) {
      stage2_main_err <<- conditionMessage(e)
      log_msg(sprintf("[%s] main %s failed (xformla=%s): %s",
                      tag, est_main, stage2_full_x_label, stage2_main_err))
      NULL
    }
  )

  is_mem_error <- !is.null(stage2_main_err) && grepl(
    "cannot allocate|cannot allocate vector|ベクトルを割り当てることができません",
    stage2_main_err, ignore.case = TRUE
  )
  if (is.null(att_main) && is_mem_error && isTRUE(run_config$stage2_retry_faster_mode_on_mem)) {
    log_msg(sprintf("[%s] Stage2 memory fallback: att_gt を faster_mode=TRUE で再試行", tag))
    att_main <- tryCatch(
      run_att_gt(panel, control_group = ctrl_grp,
                 biters = biters, bstrap = TRUE, cband = TRUE,
                 base_period = "varying", tag = paste0(tag, "_main_fast"),
                 est_method = est_main,
                 xformla = stage2_full_xformla,
                 xformla_label = stage2_full_x_label,
                 print_details = att_gt_print_details,
                 capture_att_gt_console = capture_att_gt_console,
                 faster_mode = TRUE),
      error = function(e) {
        log_msg(sprintf("[%s] main %s faster_mode memory fallback failed: %s",
                        tag, est_main, conditionMessage(e)))
        NULL
      }
    )
    if (!is.null(att_main)) stage2_used_fastmem_fallback <- TRUE
  }

  if (is.null(att_main) && is_mem_error && isTRUE(run_config$memory_fallback_to_no_boot)) {
    log_msg(sprintf("[%s] Stage2 memory fallback: att_gt を bstrap=FALSE で再試行", tag))
    att_main <- tryCatch(
      run_att_gt(panel, control_group = ctrl_grp,
                 biters = 0, bstrap = FALSE, cband = FALSE,
                 base_period = "varying", tag = paste0(tag, "_main_noboot"),
                 est_method = est_main,
                 xformla = stage2_full_xformla,
                 xformla_label = stage2_full_x_label,
                 print_details = att_gt_print_details,
                 capture_att_gt_console = capture_att_gt_console,
                 faster_mode = FALSE),
      error = function(e) {
        log_msg(sprintf("[%s] main %s memory fallback failed: %s",
                        tag, est_main, conditionMessage(e)))
        NULL
      }
    )
    if (!is.null(att_main)) stage2_used_memory_fallback <- TRUE
  }

  if (is.null(att_main) && stage2_one_step_fallback) {
    log_msg(sprintf("[%s] Stage2 one-step fallback: try xformla=%s", tag, stage2_fb_x_label))
    att_main <- tryCatch(
      run_att_gt(panel, control_group = ctrl_grp,
                 biters = biters, bstrap = TRUE, cband = TRUE,
                 base_period = "varying", tag = paste0(tag, "_main_fb1"),
                 est_method = est_main,
                 xformla = stage2_fb_xformla,
                 xformla_label = stage2_fb_x_label,
                 print_details = att_gt_print_details,
                 capture_att_gt_console = capture_att_gt_console),
      error = function(e) {
        log_msg(sprintf("[%s] main %s fallback failed (xformla=%s): %s",
                        tag, est_main, stage2_fb_x_label, conditionMessage(e)))
        NULL
      }
    )
    if (!is.null(att_main)) stage2_used_fallback <- TRUE
  }

  if (is.null(att_main)) {
    log_msg(sprintf("[%s] 全推定失敗: スキップ", tag))
    return(invisible(NULL))
  }

  if (stage2_used_fallback) {
    log_msg(sprintf("[%s] Stage2 formula used: %s (fallback)", tag, stage2_fb_x_label))
  } else {
    log_msg(sprintf("[%s] Stage2 formula used: %s", tag, stage2_full_x_label))
  }
  if (stage2_used_memory_fallback) {
    log_msg(sprintf("[%s] Stage2 bootstrap mode: att_gt=bstrapFALSE (memory fallback)", tag))
  }
  if (stage2_used_fastmem_fallback) {
    log_msg(sprintf("[%s] Stage2 solver mode: faster_mode=TRUE (memory fallback)" , tag))
  }

  # 退化チェック: nonzero_att=0 または finite_se=0 なら結果を保存せず中断 [指摘1 対応]
  d <- diagnose_att_obj(att_main, tag)
  log_msg(sprintf("[%s] 主推定完了: total=%d nonzero_att=%d finite_se=%d",
                  tag, d$total, d$nonzero_att, d$finite_se))

  if (d$nonzero_att == 0 || d$finite_se == 0) {
    log_msg(sprintf(
      "[%s] 警告: 推定が退化しています (nonzero_att=%d, finite_se=%d)。",
      tag, d$nonzero_att, d$finite_se))
    log_msg(sprintf(
      "[%s] 考えられる原因: コホートサイズが小さすぎる / 共変量の多重共線性 / 対照群不足",
      tag))
    log_msg(sprintf("[%s] → 退化推定を保存せず中断します。", tag))
    return(invisible(NULL))
  }

  run_universal_ref <- isTRUE(run_config$run_universal_ref)

  # --- 6d: 参考用 base_period = "universal" ---
  #   pre-trend の見た目確認用。退化することがあるので結果には使わない。
  if (run_universal_ref) {
    log_msg(sprintf("[%s] Stage3: 参考推定 (base_period=universal, bootstrap なし)", tag))
    att_univ_ref <- tryCatch(
      run_att_gt(panel, control_group = ctrl_grp,
                 biters = 0, bstrap = FALSE, cband = FALSE,
                 base_period = "universal", tag = paste0(tag, "_univ_ref"),
                 est_method = "dr",
                 print_details = att_gt_print_details,
                 capture_att_gt_console = capture_att_gt_console),
      error = function(e) {
        log_msg(sprintf("[%s] universal ref failed (無視): %s", tag, conditionMessage(e))); NULL
      }
    )
    if (!is.null(att_univ_ref)) {
      d_u <- diagnose_att_obj(att_univ_ref, paste0(tag, "_univ"))
      log_msg(sprintf("[%s] universal ref: nonzero=%d (参考のみ)", tag, d_u$nonzero_att))
    }
  } else {
    log_msg(sprintf("[%s] Stage3: 参考推定 (universal) をスキップ", tag))
  }

  # --- 6e: 集計 (CS2021 Section 3) ---
  # na.rm=TRUE: ATT(g,t) に NA セルが残る場合でも aggte が落ちないようにする [Fix-4]
  dyn <- tryCatch(
    aggte(att_main, type = "dynamic",  bstrap = TRUE, biters = biters, cband = TRUE,  na.rm = TRUE),
    error = function(e) { log_msg(sprintf("[%s] aggte dynamic failed: %s",  tag, conditionMessage(e))); NULL })
  grp <- tryCatch(
    aggte(att_main, type = "group",    bstrap = TRUE, biters = biters, cband = TRUE,  na.rm = TRUE),
    error = function(e) { log_msg(sprintf("[%s] aggte group failed: %s",    tag, conditionMessage(e))); NULL })
  cal <- tryCatch(
    aggte(att_main, type = "calendar", bstrap = TRUE, biters = biters, cband = TRUE,  na.rm = TRUE),
    error = function(e) { log_msg(sprintf("[%s] aggte calendar failed: %s", tag, conditionMessage(e))); NULL })

  # θ^{bal}_{es} (CS2021 eq.3.6)
  bal <- balanced_aggte(att_main, e0 = 12, biters = biters, tag = tag)

  # --- 6f: Pre-trend 検定 ---
  pretrend_report(att_main, tag = tag)

  # --- 6g: 結果保存 ---
  # CS2021_DEBUG_TAG が設定されている場合はデバッグ用サブディレクトリに書く [Fix-3]
  prefix <- file.path(debug_output_dir, tag)

  att_df_save <- extract_att_df(att_main)
  write.csv(att_df_save, paste0(prefix, "_att_gt.csv"), row.names = FALSE)
  log_msg(sprintf("[%s] ATT(g,t): %d 推定値保存", tag, nrow(att_df_save)))

  save_aggte <- function(obj, suffix) {
    if (is.null(obj)) return(invisible(NULL))
    tryCatch({
      s <- summary(obj)$aggte
      if (!is.null(s) && nrow(s) > 0)
        write.csv(s, paste0(prefix, "_", suffix, ".csv"), row.names = FALSE)
      log_msg(sprintf("[%s] %s saved (overall ATT=%.4f SE=%.4f)",
                      tag, suffix, obj$overall.att, obj$overall.se))
    }, error = function(e) {
      log_msg(sprintf("[%s] %s save failed: %s", tag, suffix, conditionMessage(e)))
    })
  }
  save_aggte(dyn, "dynamic")
  save_aggte(grp, "group")
  save_aggte(cal, "calendar")
  if (!is.null(bal)) save_aggte(bal, "dynamic_balanced")

  # テキストサマリ
  sink(paste0(prefix, "_summary.txt"))
  cat(sprintf("=== %s: att_gt (base_period=varying) ===\n", tag))
  tryCatch(print(summary(att_main)), error = function(e) cat(conditionMessage(e), "\n"))
  cat(sprintf("\n=== %s: dynamic ===\n", tag))
  tryCatch(print(summary(dyn)),      error = function(e) cat(conditionMessage(e), "\n"))
  cat(sprintf("\n=== %s: group ===\n", tag))
  tryCatch(print(summary(grp)),      error = function(e) cat(conditionMessage(e), "\n"))
  cat(sprintf("\n=== %s: calendar ===\n", tag))
  tryCatch(print(summary(cal)),      error = function(e) cat(conditionMessage(e), "\n"))
  if (!is.null(bal)) {
    cat(sprintf("\n=== %s: dynamic_balanced (e0=12) ===\n", tag))
    tryCatch(print(summary(bal)), error = function(e) cat(conditionMessage(e), "\n"))
  }
  sink()
  log_msg(sprintf("[%s] summary report saved", tag))

  invisible(list(att_obj = att_main,
                 dyn = dyn, grp = grp, cal = cal, bal = bal))
}

# ---------------------------------------------------------------------------
# STEP 7: サブグループ分析  [Add-1]
#   公式誘導あり (official=1) / なし (official=0) を別々に推定し
#   post 効果の差を確認する (主張B の中核)。
#
#   実装方針:
#     official 層ごとに母集団を分ける。
#     その層内で treated / never / not-yet を構成して推定する。
#     → main の control_group 方針（notyettreated 優先）と整合。
# ---------------------------------------------------------------------------
run_subgroup <- function(panel_full, run_config) {
  log_msg("STEP 7: サブグループ分析 (公式誘導 あり / なし)")

  results <- list()
  biters <- as.integer(run_config$biters)
  if (is.na(biters) || biters < 0L) biters <- 999L
  subgroup_never_n <- as.integer(run_config$subgroup_never_n)
  if (is.na(subgroup_never_n) || subgroup_never_n < 0L) subgroup_never_n <- 0L

  for (off_val in c(1L, 0L)) {
    label <- if (off_val == 1L) "official_yes" else "official_no"
    jp    <- if (off_val == 1L) "公式誘導あり" else "公式誘導なし"
    log_msg(sprintf("[subgroup] %s (official=%d)", jp, off_val))

    # 対象 official 層で推定（層内で never/not-yet を構成）
    sub <- panel_full[panel_full$official == off_val, ]

    # サブグループ推定のメモリ対策（任意）
    # run_config$subgroup_never_n > 0 のとき、never-treated を上限件数でサンプリング
    if (subgroup_never_n > 0L) {
      never_pkgs <- unique(sub$package[sub$G == 0L])
      if (length(never_pkgs) > subgroup_never_n) {
        set.seed(42 + off_val)
        keep_never <- sample(never_pkgs, subgroup_never_n)
        treat_pkgs <- unique(sub$package[sub$G > 0L])
        keep_pkgs <- c(treat_pkgs, keep_never)
        before_pkg <- length(unique(sub$package))
        sub <- sub[sub$package %in% keep_pkgs, ]
        after_pkg <- length(unique(sub$package))
        log_msg(sprintf("[subgroup] %s: sampled never-treated %d -> %d (packages %d -> %d)",
                        jp, length(never_pkgs), length(keep_never), before_pkg, after_pkg))
      }
    }

    n_treat <- length(unique(sub$package[sub$G > 0]))
    if (n_treat < 10L) {
      log_msg(sprintf("[subgroup] %s: treated が少なすぎる (n=%d) → スキップ", jp, n_treat))
      next
    }

    res <- tryCatch(
      run_pipeline(sub, tag = label, run_config = run_config),
      error = function(e) {
        log_msg(sprintf("[subgroup] %s: 推定失敗: %s", jp, conditionMessage(e)))
        NULL
      }
    )
    results[[label]] <- res

    # 大規模サブグループ実行後に明示的にGC
    invisible(gc(verbose = FALSE))
  }

  # サブグループ間の差の検定 (simple ATT の差)
  if (!is.null(results[["official_yes"]]) && !is.null(results[["official_no"]])) {
    # [BugFix-A] $att_obj を渡す ($att は data.frame なので aggte() に渡せない)
    att_yes <- results[["official_yes"]]$att_obj
    att_no  <- results[["official_no"]]$att_obj

    # [BugFix-B] aggte(type="simple") に bstrap=TRUE を明示して SE を再計算
    simple_yes <- tryCatch(
      aggte(att_yes, type = "simple", bstrap = TRUE, biters = biters, cband = FALSE, na.rm = TRUE),
      error = function(e) {
        log_msg(sprintf("[subgroup] simple_yes failed: %s", conditionMessage(e))); NULL
      }
    )
    simple_no <- tryCatch(
      aggte(att_no,  type = "simple", bstrap = TRUE, biters = biters, cband = FALSE, na.rm = TRUE),
      error = function(e) {
        log_msg(sprintf("[subgroup] simple_no failed: %s", conditionMessage(e))); NULL
      }
    )

    if (!is.null(simple_yes) && !is.null(simple_no)) {
      diff_att <- simple_yes$overall.att - simple_no$overall.att
      se_diff  <- sqrt(simple_yes$overall.se^2 + simple_no$overall.se^2)
      z_diff   <- diff_att / se_diff
      p_diff   <- 2 * (1 - pnorm(abs(z_diff)))

      diff_row <- data.frame(
        subgroup     = c("official_yes", "official_no", "diff_yes_minus_no"),
        overall_att  = c(simple_yes$overall.att, simple_no$overall.att, diff_att),
        overall_se   = c(simple_yes$overall.se,  simple_no$overall.se,  se_diff),
        z            = c(simple_yes$overall.att / simple_yes$overall.se,
                         simple_no$overall.att  / simple_no$overall.se,
                         z_diff),
        p            = c(2*(1-pnorm(abs(simple_yes$overall.att/simple_yes$overall.se))),
                         2*(1-pnorm(abs(simple_no$overall.att /simple_no$overall.se))),
                         p_diff)
      )

      write.csv(diff_row,
                file.path(output_dir, "subgroup_comparison.csv"),
                row.names = FALSE)

      log_msg(sprintf(
        "[subgroup] 公式誘導あり ATT=%.4f SE=%.4f p=%.4f",
        simple_yes$overall.att, simple_yes$overall.se,
        2*(1-pnorm(abs(simple_yes$overall.att/simple_yes$overall.se)))))
      log_msg(sprintf(
        "[subgroup] 公式誘導なし ATT=%.4f SE=%.4f p=%.4f",
        simple_no$overall.att,  simple_no$overall.se,
        2*(1-pnorm(abs(simple_no$overall.att /simple_no$overall.se)))))
      log_msg(sprintf(
        "[subgroup] 差 (あり－なし): diff=%.4f SE=%.4f z=%.2f p=%.4f",
        diff_att, se_diff, z_diff, p_diff))
    }
  }

  invisible(results)
}

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
main <- function() {
  if (file.exists(log_file)) file.remove(log_file)
  log_msg("START: CS2021 DID v8")
  log_msg("input_json=",     input_json)
  log_msg("classified_csv=", classified_csv)
  log_msg("output_dir=",     output_dir)

  run_config <- build_run_config()
  log_msg("run profile: final-primary defaults")
  log_msg(sprintf(
    "config: est_method=%s force_control_group=%s stage2_x_mode=%s run_subgroup=%s biters=%d",
    run_config$est_method,
    run_config$force_control_group,
    run_config$stage2_x_mode,
    ifelse(isTRUE(run_config$run_subgroup), "1", "0"),
    as.integer(run_config$biters)
  ))
  log_msg(sprintf(
    "config: sample_treated_n=%d max_period=%d min_cohort_size=%d max_post_period=%d use_panel_cache=%s",
    as.integer(run_config$sample_treated_n),
    as.integer(run_config$max_period),
    as.integer(run_config$min_cohort_size),
    as.integer(run_config$max_post_period),
    ifelse(isTRUE(run_config$use_panel_cache), "1", "0")
  ))
  log_msg(sprintf(
    "config(change-candidate): diag_only=%s skip_diagnostics=%s",
    ifelse(isTRUE(run_config$diag_only), "1", "0"),
    ifelse(isTRUE(run_config$skip_diagnostics), "1", "0")
  ))
  log_msg(sprintf(
    "config(lighten): skip_control_selection_when_forced=%s att_gt_print_details=%s capture_att_gt_console=%s",
    ifelse(isTRUE(run_config$skip_control_selection_when_forced), "1", "0"),
    ifelse(isTRUE(run_config$att_gt_print_details), "1", "0"),
    ifelse(isTRUE(run_config$capture_att_gt_console), "1", "0")
  ))

  use_cache <- isTRUE(run_config$use_panel_cache)
  run_subgroup_flag <- isTRUE(run_config$run_subgroup)

  # STEP 1: パネル構築（キャッシュ対応）
  panel <- NULL
  if (use_cache && file.exists(panel_cache_file)) {
    cache_mtime <- file.info(panel_cache_file)$mtime
    in1_mtime <- file.info(input_json)$mtime
    in2_mtime <- file.info(classified_csv)$mtime
    script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
    script_path <- if (length(script_arg) > 0) sub("^--file=", "", script_arg[[1]]) else NA_character_
    script_mtime <- if (!is.na(script_path) && file.exists(script_path)) file.info(script_path)$mtime else as.POSIXct(NA)
    if (!is.na(cache_mtime) && !is.na(in1_mtime) && !is.na(in2_mtime) &&
        cache_mtime >= in1_mtime && cache_mtime >= in2_mtime &&
        (is.na(script_mtime) || cache_mtime >= script_mtime)) {
      log_msg("panel cache hit: ", panel_cache_file)
      panel <- readRDS(panel_cache_file)
    } else {
      if (!is.na(script_mtime) && !is.na(cache_mtime) && cache_mtime < script_mtime) {
        log_msg("panel cache is stale vs script; rebuild required")
      } else {
        log_msg("panel cache is stale; rebuild required")
      }
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
    # did パッケージは period=0 を受け付けないため 1-based に変換する。
    # G と period を同時にシフトすることで相対関係 (rel = period - G) は保たれる。
    # log_dl_pre3 は build_panel 内で 0-based のまま計算済みなので影響なし。
    panel$period <- as.integer(panel$period) + 1L
    treated_idx  <- panel$G > 0
    panel$G[treated_idx] <- as.integer(panel$G[treated_idx]) + 1L
    panel$age_at_event[treated_idx] <- as.integer(panel$age_at_event[treated_idx]) + 1L
    log_msg("panel normalize: shifted period/G/age_at_event to 1-based index for did")
  }

  # 本番推定の安定設定（必要時は build_run_config() を変更）
  sample_treated_n <- as.integer(run_config$sample_treated_n)
  max_period <- as.integer(run_config$max_period)
  min_cohort_size <- as.integer(run_config$min_cohort_size)
  max_post_period <- as.integer(run_config$max_post_period)

  if (sample_treated_n > 0L) {
    set.seed(42)
    treated_pkgs <- unique(panel$package[panel$G > 0L])
    if (length(treated_pkgs) > sample_treated_n) {
      keep_treated <- sample(treated_pkgs, sample_treated_n)
      keep_never <- unique(panel$package[panel$G == 0L])
      keep_pkgs <- c(keep_treated, keep_never)
      panel <- panel[panel$package %in% keep_pkgs, ]
      log_msg("sample option: sample_treated_n=", sample_treated_n,
              " applied; kept treated packages=", length(keep_treated))
    } else {
      log_msg("sample option: sample_treated_n ignored (treated <= sample size)")
    }
  }

  if (max_period >= 0L) {
    panel <- panel[panel$period <= max_period, ]
    log_msg("sample option: max_period=", max_period, " applied")
  }

  panel <- apply_stability_filters(panel,
                                   min_cohort_size = min_cohort_size,
                                   max_post_period = max_post_period)

  log_msg(sprintf("Panel: rows=%d, packages=%d",
                  nrow(panel), length(unique(panel$package))))

  biters <- as.integer(run_config$biters)
  if (is.na(biters) || biters < 0) biters <- 999L
  log_msg("biters=", biters)

  # STEP 2-6: 全体推定
  log_msg("STEP 2-6: 全体推定")
  run_config$biters <- biters
  res_all <- run_pipeline(panel, tag = "overall", run_config = run_config)

  # STEP 7: サブグループ分析 (公式誘導 あり / なし)
  if (run_subgroup_flag) {
    run_subgroup(panel, run_config = run_config)
  } else {
    log_msg("STEP 7: サブグループ分析をスキップ (run_subgroup=0)")
  }

  log_msg(sprintf("DONE. 出力先: %s", output_dir))
}

if (sys.nframe() == 0) {
  main()
}
