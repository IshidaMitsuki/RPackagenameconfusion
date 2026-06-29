suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(readr)
  library(tidyr)
})

project_dir <- normalizePath(file.path(getwd(), "RPackagenameconfusion"), winslash = "/", mustWork = FALSE)
if (!dir.exists(project_dir)) {
  project_dir <- normalizePath(file.path(getwd(), ".."), winslash = "/", mustWork = FALSE)
}

figure_dir <- file.path(project_dir, "figures", "cs2021_did_r_v8")
bjs_dir <- file.path(figure_dir, "bjs_imputation")
report_dir <- file.path(bjs_dir, "report")
if (!dir.exists(report_dir)) dir.create(report_dir, recursive = TRUE)

required_files <- c(
  file.path(bjs_dir, "bjs_bootstrap_summary.csv"),
  file.path(bjs_dir, "bjs_summary.csv"),
  file.path(bjs_dir, "bjs_dynamic_all.csv"),
  file.path(bjs_dir, "bjs_pretrend_test_summary.csv"),
  file.path(bjs_dir, "bjs_diagnostics_summary.csv"),
  file.path(bjs_dir, "bjs_inference_status.csv")
)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0L) {
  stop("Missing required BJS output files:\n", paste(missing_files, collapse = "\n"))
}

boot <- read_csv(file.path(bjs_dir, "bjs_bootstrap_summary.csv"), show_col_types = FALSE)
summary_df <- read_csv(file.path(bjs_dir, "bjs_summary.csv"), show_col_types = FALSE)
dynamic <- read_csv(file.path(bjs_dir, "bjs_dynamic_all.csv"), show_col_types = FALSE)
pretrend <- read_csv(file.path(bjs_dir, "bjs_pretrend_test_summary.csv"), show_col_types = FALSE)
diag <- read_csv(file.path(bjs_dir, "bjs_diagnostics_summary.csv"), show_col_types = FALSE)
inference <- read_csv(file.path(bjs_dir, "bjs_inference_status.csv"), show_col_types = FALSE)

sample_levels <- c(
  "overall",
  "official_before_yes",
  "official_before_no",
  "gte13",
  "preobs_ge12",
  "glt12",
  "gte12",
  "official_before_yes_gte13",
  "official_before_no_gte13",
  "official_before_yes_preobs_ge12",
  "official_before_no_preobs_ge12"
)

sample_labels <- c(
  overall = "Overall",
  official_before_yes = "Official before: yes",
  official_before_no = "Official before: no",
  gte13 = "G >= 13",
  preobs_ge12 = "Pre obs >= 12",
  glt12 = "G < 12",
  gte12 = "G >= 12",
  official_before_yes_gte13 = "Official yes + G >= 13",
  official_before_no_gte13 = "Official no + G >= 13",
  official_before_yes_preobs_ge12 = "Official yes + pre obs >= 12",
  official_before_no_preobs_ge12 = "Official no + pre obs >= 12"
)

label_sample <- function(x) {
  out <- unname(sample_labels[x])
  out[is.na(out)] <- x[is.na(out)]
  out
}

format_num <- function(x, digits = 3) {
  ifelse(is.na(x), "", formatC(x, format = "f", digits = digits))
}

format_p <- function(x) {
  ifelse(is.na(x), "", ifelse(x < 0.001, "<0.001", formatC(x, format = "f", digits = 3)))
}

to_pct_from_log <- function(x) {
  100 * (exp(x) - 1)
}

md_table <- function(df) {
  if (nrow(df) == 0L) return(character(0))
  header <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep <- paste0("| ", paste(rep("---", ncol(df)), collapse = " | "), " |")
  rows <- apply(df, 1, function(x) paste0("| ", paste(x, collapse = " | "), " |"))
  c(header, sep, rows)
}

theme_report <- function() {
  theme_minimal(base_size = 12) +
    theme(
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      legend.background = element_rect(fill = "white", color = NA),
      legend.key = element_rect(fill = "white", color = NA),
      text = element_text(color = "black"),
      axis.text = element_text(color = "black"),
      axis.title = element_text(color = "black"),
      plot.title = element_text(color = "black"),
      panel.grid.minor = element_blank(),
      plot.title.position = "plot",
      legend.position = "bottom"
    )
}

main_samples <- c("overall", "official_before_yes", "official_before_no")
robust_samples <- c("overall", "gte13", "preobs_ge12")
bootstrap_samples <- c("overall", "official_before_yes", "official_before_no", "gte13", "preobs_ge12")

dynamic_plot_df <- dynamic %>%
  filter(sample %in% main_samples, event_time >= -24, event_time <= 60) %>%
  mutate(sample_label = factor(label_sample(sample), levels = label_sample(main_samples)))

p_dynamic <- ggplot(dynamic_plot_df, aes(x = event_time, y = att, color = sample_label)) +
  geom_hline(yintercept = 0, linewidth = 0.3, color = "gray45") +
  geom_vline(xintercept = -0.5, linewidth = 0.3, linetype = "dashed", color = "gray45") +
  geom_line(linewidth = 0.8) +
  labs(
    title = "BJS imputation event-study path",
    x = "Event time",
    y = "Imputed ATT on log downloads",
    color = NULL
  ) +
  theme_report()
ggsave(file.path(report_dir, "bjs_dynamic_event_study.png"), p_dynamic, width = 9, height = 5.5, dpi = 180)

forest_df <- boot %>%
  filter(sample %in% bootstrap_samples, estimand == "dynamic_att_event_equal_0_60") %>%
  mutate(
    sample_label = factor(label_sample(sample), levels = rev(label_sample(bootstrap_samples))),
    pct = to_pct_from_log(bootstrap_mean),
    pct_low = to_pct_from_log(bootstrap_ci_low),
    pct_high = to_pct_from_log(bootstrap_ci_high)
  )

p_forest <- ggplot(forest_df, aes(x = bootstrap_mean, y = sample_label)) +
  geom_vline(xintercept = 0, linewidth = 0.3, color = "gray45") +
  geom_errorbarh(aes(xmin = bootstrap_ci_low, xmax = bootstrap_ci_high), height = 0.2, linewidth = 0.7) +
  geom_point(size = 2.4, color = "#1f6f8b") +
  labs(
    title = "BJS dynamic ATT with package-cluster bootstrap intervals",
    x = "Dynamic ATT, event-time equal average over e = 0..60",
    y = NULL
  ) +
  theme_report()
ggsave(file.path(report_dir, "bjs_dynamic_att_forest.png"), p_forest, width = 8.5, height = 4.8, dpi = 180)

balanced_df <- boot %>%
  filter(sample %in% bootstrap_samples, grepl("^balanced_event_equal_h", estimand)) %>%
  mutate(
    horizon = as.integer(sub("balanced_event_equal_h", "", estimand)),
    sample_label = factor(label_sample(sample), levels = label_sample(bootstrap_samples))
  )

p_balanced <- ggplot(balanced_df, aes(x = horizon, y = bootstrap_mean, color = sample_label)) +
  geom_hline(yintercept = 0, linewidth = 0.3, color = "gray45") +
  geom_errorbar(aes(ymin = bootstrap_ci_low, ymax = bootstrap_ci_high), width = 1.2, linewidth = 0.45, alpha = 0.65) +
  geom_line(linewidth = 0.75) +
  geom_point(size = 2) +
  scale_x_continuous(breaks = c(12, 24, 36, 48)) +
  labs(
    title = "BJS balanced horizon summaries",
    x = "Balanced horizon",
    y = "Balanced event-time equal ATT",
    color = NULL
  ) +
  theme_report()
ggsave(file.path(report_dir, "bjs_balanced_horizon_paths.png"), p_balanced, width = 9, height = 5.5, dpi = 180)

pretrend_plot_df <- pretrend %>%
  filter(sample %in% c(bootstrap_samples, "glt12", "gte12")) %>%
  mutate(
    sample_label = factor(label_sample(sample), levels = rev(label_sample(c(bootstrap_samples, "glt12", "gte12")))),
    neg_log10_p = -log10(pmax(p_value, .Machine$double.xmin))
  )

p_pretrend <- ggplot(pretrend_plot_df, aes(x = neg_log10_p, y = sample_label)) +
  geom_col(fill = "#9b5d42", width = 0.65) +
  geom_vline(xintercept = -log10(0.05), linewidth = 0.35, linetype = "dashed", color = "gray35") +
  labs(
    title = "BJS pre-trend/no-anticipation diagnostic",
    x = "-log10(Wald p-value); dashed line = p = 0.05",
    y = NULL
  ) +
  theme_report()
ggsave(file.path(report_dir, "bjs_pretrend_wald_pvalues.png"), p_pretrend, width = 8.5, height = 5, dpi = 180)

composition_df <- diag %>%
  filter(sample %in% bootstrap_samples) %>%
  mutate(sample_label = factor(label_sample(sample), levels = label_sample(bootstrap_samples))) %>%
  select(sample_label, treated_packages_with_post, never_packages) %>%
  pivot_longer(cols = c(treated_packages_with_post, never_packages), names_to = "type", values_to = "n") %>%
  mutate(type = recode(type, treated_packages_with_post = "Treated with post", never_packages = "Never treated"))

p_comp <- ggplot(composition_df, aes(x = sample_label, y = n, fill = type)) +
  geom_col(position = "dodge", width = 0.72) +
  labs(
    title = "BJS sample composition",
    x = NULL,
    y = "Packages",
    fill = NULL
  ) +
  theme_report() +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))
ggsave(file.path(report_dir, "bjs_sample_composition.png"), p_comp, width = 9, height = 5, dpi = 180)

main_table <- boot %>%
  filter(sample %in% bootstrap_samples, estimand == "dynamic_att_event_equal_0_60") %>%
  left_join(diag %>% select(sample, treated_packages, treated_packages_with_post, never_packages, post_treated_observations), by = "sample") %>%
  mutate(
    Specification = label_sample(sample),
    `Treated packages` = formatC(treated_packages, big.mark = ",", format = "d"),
    `With post obs` = formatC(treated_packages_with_post, big.mark = ",", format = "d"),
    `ATT` = format_num(bootstrap_mean, 4),
    `SE` = format_num(bootstrap_se, 4),
    `95% CI` = paste0("[", format_num(bootstrap_ci_low, 4), ", ", format_num(bootstrap_ci_high, 4), "]"),
    `% approx.` = paste0(format_num(to_pct_from_log(bootstrap_mean), 1), "%"),
    `Bootstrap` = paste0(n_success, "/", n_requested)
  ) %>%
  select(Specification, `Treated packages`, `With post obs`, ATT, SE, `95% CI`, `% approx.`, Bootstrap)

balanced_table <- balanced_df %>%
  filter(sample %in% c("overall", "official_before_yes", "official_before_no", "gte13", "preobs_ge12")) %>%
  mutate(
    Specification = label_sample(sample),
    Horizon = paste0("h", horizon),
    ATT = format_num(bootstrap_mean, 4),
    SE = format_num(bootstrap_se, 4),
    `95% CI` = paste0("[", format_num(bootstrap_ci_low, 4), ", ", format_num(bootstrap_ci_high, 4), "]")
  ) %>%
  select(Specification, Horizon, ATT, SE, `95% CI`)

pretrend_table <- pretrend %>%
  filter(sample %in% c(bootstrap_samples, "glt12", "gte12")) %>%
  left_join(summary_df %>% select(sample, mean_pre_att_event_equal, max_abs_pre_att, pre_event_cells), by = "sample") %>%
  mutate(
    Specification = label_sample(sample),
    `Lead k` = k,
    `Clusters` = formatC(n_clusters, big.mark = ",", format = "d"),
    `Wald p` = format_p(p_value),
    `Mean pre residual` = format_num(mean_pre_att_event_equal, 4),
    `Max abs pre residual` = format_num(max_abs_pre_att, 4),
    `Pre cells` = pre_event_cells
  ) %>%
  select(Specification, `Lead k`, Clusters, `Wald p`, `Mean pre residual`, `Max abs pre residual`, `Pre cells`)

diag_table <- diag %>%
  filter(sample %in% bootstrap_samples) %>%
  mutate(
    Specification = label_sample(sample),
    Packages = formatC(packages, big.mark = ",", format = "d"),
    `Treated packages` = formatC(treated_packages, big.mark = ",", format = "d"),
    `Treated with post` = formatC(treated_packages_with_post, big.mark = ",", format = "d"),
    `Never treated` = formatC(never_packages, big.mark = ",", format = "d"),
    `Untreated obs` = formatC(untreated_observations, big.mark = ",", format = "d"),
    `Post treated obs` = formatC(post_treated_observations, big.mark = ",", format = "d"),
    `FE converged` = ifelse(fit_converged, "Yes", "No")
  ) %>%
  select(Specification, Packages, `Treated packages`, `Treated with post`, `Never treated`, `Untreated obs`, `Post treated obs`, `FE converged`)

overall_att <- forest_df %>% filter(sample == "overall") %>% slice(1)
yes_att <- forest_df %>% filter(sample == "official_before_yes") %>% slice(1)
no_att <- forest_df %>% filter(sample == "official_before_no") %>% slice(1)
gte13_att <- forest_df %>% filter(sample == "gte13") %>% slice(1)
preobs_att <- forest_df %>% filter(sample == "preobs_ge12") %>% slice(1)

report_lines <- c(
  "# BJS imputation v1 result report",
  "",
  paste0("作成日: ", format(Sys.Date(), "%Y-%m-%d")),
  "",
  "このレポートは、`analysis/script/method_bjs_imputation_v1.R` の出力を、論文・発表で確認しやすい形に整理したものである。イベントはC&S DIDと同じく、CRANパッケージと同名の非公式GitHubリポジトリが初めて出現した時点である。アウトカムは月次CRANダウンロード数の対数 `log_dl` である。",
  "",
  "## 1. BJS imputationで何を推定しているか",
  "",
  "BJS imputationでは、まず未処置観測だけを使って、処置がなかった場合のダウンロード数を予測する。今回の主仕様では、未処置アウトカムをパッケージ固定効果と時点固定効果で表す。",
  "",
  "```text",
  "log_dl_it = alpha_i + lambda_t + error_it",
  "```",
  "",
  "このモデルを `G == 0` または `period < G` の観測だけで推定し、処置後の観測について反実仮想 `y0_hat_it` を補完する。BJSの処置効果は、実際の `log_dl_it` と補完された未処置アウトカムの差として計算する。",
  "",
  "```text",
  "tau_hat_it = log_dl_it - y0_hat_it",
  "```",
  "",
  "主な推定量は、イベント後 `e = 0..60` の平均である。`dynamic_att_event_equal_0_60` はイベント時点セルを等しく重みづけする平均、`dynamic_att_obs_weighted_0_60` は観測数で重みづけする平均である。このレポートでは、C&S DIDとの比較を意識して、主に event-time equal の値を中心に読む。",
  "",
  "## 2. 推論と注意点",
  "",
  paste0("今回のBJS推論は package-cluster bootstrap による。bootstrapは `", inference$bootstrap_reps_requested[1], "` 回で、論文向けに使えるbootstrap推論は `", ifelse(inference$paper_facing_inference_available[1], "利用可能", "未完了"), "` である。これはBJS論文のclosed-form conservative variance estimatorそのものではなく、パッケージ単位で再標本化してBJS推定を繰り返した実務的なbootstrap SEとして報告する。"),
  "",
  "一方、`bjs_dynamic_all.csv` に含まれる `se_naive` は記述的な診断用であり、論文での主な信頼区間としては使わない。",
  "",
  "## 3. 仕様とサンプルの意味",
  "",
  "`overall` は、G<12を除外しない主分析である。`official_before_yes` と `official_before_no` は、イベント前にCRAN/GitHub間の導線が確認されていたかどうかで分けたsubgroup分析である。`gte13` はイベント前に少なくとも12期程度の観測を持つパッケージに絞った感度分析であり、`preobs_ge12` は実際の処置前観測数が12以上あるものに絞る感度分析である。",
  "",
  "重要なのは、BJSの主モデルには `official_before_yes` や `preobs_ge12` を共変量として直接入れているわけではない点である。パッケージ固定効果を入れるため、時間不変に近い変数は固定効果と重なりやすい。そこで、BJSでは未処置アウトカムモデルを同じ形に保ったまま、サンプルを分けて結果が変わるかを見る。",
  "",
  "## 4. 主な結論",
  "",
  paste0("第一に、全体サンプルのBJS Dynamic ATTは `", format_num(overall_att$bootstrap_mean, 4), "` であり、95% bootstrap CIは `[", format_num(overall_att$bootstrap_ci_low, 4), ", ", format_num(overall_att$bootstrap_ci_high, 4), "]` である。対数値を概算の割合に直すと約 `", format_num(to_pct_from_log(overall_att$bootstrap_mean), 1), "%` であり、同名非公式GitHubリポジトリ出現後にCRANダウンロードが高いという正の関連が確認される。"),
  "",
  paste0("第二に、イベント前にCRAN/GitHub間の公式誘導に相当する導線がある `official_before_yes` では ATT が `", format_num(yes_att$bootstrap_mean, 4), "`、導線がない `official_before_no` では `", format_num(no_att$bootstrap_mean, 4), "` である。BJSでも official_before_yes の方が大きい。これは、事前に可視性・導線を持つパッケージほど、同名非公式リポジトリ出現後のDL水準も高いことを示す。"),
  "",
  paste0("第三に、`G >= 13` に限定した感度分析では ATT が `", format_num(gte13_att$bootstrap_mean, 4), "`、`preobs_ge12` では `", format_num(preobs_att$bootstrap_mean, 4), "` である。したがって、処置前観測が短いパッケージを除いても正の結果は残る。"),
  "",
  "ただし、BJSのpre-trend/no-anticipation diagnosticでは、主要サンプルでWald検定が強く棄却されている。したがって、結果は「同名非公式リポジトリ出現後にDLが増える」という頑健な記述的・準因果的な関連としては強いが、純粋な因果効果として断定するには慎重であるべきである。",
  "",
  "## 5. 主要図",
  "",
  "### 図1: BJS event-study path",
  "",
  '<p align="center"><img src="report/bjs_dynamic_event_study.png" alt="BJS event-study path" width="900"></p>',
  "",
  "この図は、BJS imputation residualをイベント時点ごとに平均した動学パスである。イベント後は全体として正の値が続き、時間が進むほど大きくなる傾向がある。official_before_yes は official_before_no より高い水準で推移している。ただし、イベント前にも正の残差が見られるため、処置前から対象群に差があった可能性を示している。",
  "",
  "### 図2: Dynamic ATTのbootstrap CI",
  "",
  '<p align="center"><img src="report/bjs_dynamic_att_forest.png" alt="BJS dynamic ATT forest" width="850"></p>',
  "",
  "この図は、`e = 0..60` の平均Dynamic ATTを仕様別に比較したものである。全仕様で信頼区間は0を上回っている。特に `official_before_yes`、`G >= 13`、`preobs_ge12` の推定値が大きい。",
  "",
  "### 図3: Balanced horizon summary",
  "",
  '<p align="center"><img src="report/bjs_balanced_horizon_paths.png" alt="BJS balanced horizon paths" width="900"></p>',
  "",
  "balanced horizonは、イベント後12、24、36、48期まで観測できるパッケージに限定して平均効果を見るものである。horizonが長くなるほどATTが大きくなっており、短期だけでなく中長期にもDL水準の差が広がるパターンが見られる。",
  "",
  "### 図4: Pre-trend/no-anticipation diagnostic",
  "",
  '<p align="center"><img src="report/bjs_pretrend_wald_pvalues.png" alt="BJS pretrend diagnostic" width="850"></p>',
  "",
  "この図は、BJSのpre-trend/no-anticipation diagnosticのWald p値を `-log10(p)` で示したものである。破線より右にあるほど5%水準で棄却される。主要サンプルではすべて棄却されており、処置前の動きが完全に揃っていたとは言いにくい。",
  "",
  "### 図5: Sample composition",
  "",
  '<p align="center"><img src="report/bjs_sample_composition.png" alt="BJS sample composition" width="900"></p>',
  "",
  "この図は、各仕様で使われたtreated with postとnever-treatedの件数を示している。official_before_yes/no の分割ではサンプルサイズが大きく異なるため、推定値の精度や解釈にも注意が必要である。",
  "",
  "## 6. Main BJS estimates",
  "",
  md_table(main_table),
  "",
  "上表の `% approx.` は `exp(ATT)-1` による概算である。BJSのATTは対数ダウンロード数の差なので、厳密にはログスケールの差として読むのが基本である。",
  "",
  "## 7. Balanced horizon estimates",
  "",
  md_table(balanced_table),
  "",
  "balanced horizonでは、観測可能な期間が十分にあるパッケージに対象が限定される。そのため、長期horizonほどサンプル構成が変わる可能性がある。ただし、今回の結果ではh12からh48にかけて一貫して正であり、horizonが長いほど推定値が大きい。",
  "",
  "## 8. Pre-trend diagnostic",
  "",
  md_table(pretrend_table),
  "",
  "BJSのpre-trend/no-anticipation testでは、処置前12期のlead係数が同時に0であるかを検定している。全体、official_before_yes、official_before_no、G>=13、preobs_ge12のいずれでもp値は非常に小さい。したがって、BJSでもC&Sと同様に、処置前差の存在を明示したうえで結果を解釈する必要がある。",
  "",
  "## 9. Sample diagnostics",
  "",
  md_table(diag_table),
  "",
  "FE推定はすべて収束している。全体ではtreated packageが3,262、そのうち処置後観測を持つものが3,024である。official_before_yesはtreated 852、official_before_noはtreated 2,410であり、official_before_yesはサンプルが小さい分、SEも大きい。",
  "",
  "## 10. C&S DIDとの関係",
  "",
  "C&S DIDは、群時点ATTを比較群の選び方や共変量調整とともに推定する方法である。一方、BJS imputationは、未処置観測だけで未処置アウトカムモデルを推定し、処置後の反実仮想を補完する方法である。両者は反実仮想の作り方が異なるため、同じ方向の結果が出るなら、特定の推定手法だけに依存した結果ではないと言いやすくなる。",
  "",
  "今回、BJSでもC&Sと同じく、同名非公式GitHubリポジトリ出現後のDL増加、official_before_yesの大きめの推定値、処置前差への注意という3点が確認された。したがって、現時点の結論は次のようにまとめられる。",
  "",
  "> 同名非公式GitHubリポジトリの出現後、CRANパッケージのダウンロード数は高い水準を示す。この関連はC&S DIDだけでなくBJS imputationでも確認され、G>=13やpreobs_ge12の感度分析でも残る。ただし、処置前の差も統計的に確認されるため、純粋な因果効果というより、パッケージの事前の可視性・人気・導線を含む関連として慎重に解釈する必要がある。",
  "",
  "## 11. 次に確認すべき点",
  "",
  "1. C&SとBJSの同じ仕様を横並びにした比較表を作り、推定値の差を整理する。",
  "2. official_before_yes/no でpre-trendの形がどの時点から違うのかを、pre-event側だけの図で確認する。",
  "3. BJSの結果をSDIDやcohort-specificな比較と照合し、反実仮想の作り方に依存しない部分を明確にする。",
  "4. 論文本文では、bootstrap SEをpackage-cluster bootstrapとして記述し、BJS closed-form conservative SEとは書かない。",
  ""
)

writeLines(report_lines, file.path(bjs_dir, "bjs_imputation_report.md"), useBytes = TRUE)

message("saved: ", file.path(bjs_dir, "bjs_imputation_report.md"))
message("saved figures in: ", report_dir)
