# Create key figures for the CS2021 DID v8 result memo.

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(readr)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args, value = TRUE)
script_path <- if (length(file_arg) > 0) {
  sub("^--file=", "", file_arg[1])
} else {
  file.path(getwd(), "analysis", "make_cs2021_v8_key_figures.R")
}
script_path <- normalizePath(script_path, winslash = "/", mustWork = FALSE)
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE)
if (!dir.exists(file.path(base_dir, "figures"))) {
  base_dir <- normalizePath(file.path(getwd(), "RPackagenameconfusion"), winslash = "/", mustWork = FALSE)
}

out_dir <- file.path(base_dir, "figures", "cs2021_did_r_v8")
report_dir <- file.path(out_dir, "report")
if (!dir.exists(report_dir)) dir.create(report_dir, recursive = TRUE)

theme_cs <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      plot.title = element_text(face = "bold", size = base_size + 2),
      plot.subtitle = element_text(color = "grey35"),
      axis.title.y = element_blank(),
      legend.position = "bottom",
      legend.title = element_blank()
    )
}

dyn <- tibble::tribble(
  ~spec, ~family, ~att, ~se,
  "Main: not-yet", "Main", 0.4011, 0.0189,
  "Official yes", "Official subgroup", 0.4964, 0.0402,
  "Official no", "Official subgroup", 0.3699, 0.0203,
  "Never-treated only", "Sensitivity", 0.3698, 0.0189,
  "G>=13 pre12", "Sensitivity", 0.3290, 0.0199,
  "G<12 subgroup", "Sensitivity", 0.4154, 0.0481,
  "G>=12 subgroup", "Sensitivity", 0.3513, 0.0209,
  "Official yes + never", "Official sensitivity", 0.4959, 0.0394,
  "Official yes + G>=13 pre12", "Official sensitivity", 0.4698, 0.0419,
  "Official no + never", "Official sensitivity", 0.3236, 0.0197,
  "Official no + G>=13 pre12", "Official sensitivity", 0.2854, 0.0229
) %>%
  mutate(
    ci_low = att - 1.96 * se,
    ci_high = att + 1.96 * se,
    spec = factor(spec, levels = rev(spec))
  )

p_forest <- ggplot(dyn, aes(x = att, y = spec, color = family)) +
  geom_vline(xintercept = 0, linewidth = 0.4, color = "grey70") +
  geom_errorbarh(aes(xmin = ci_low, xmax = ci_high), height = 0, linewidth = 0.7) +
  geom_point(size = 2.4) +
  scale_color_manual(values = c(
    "Main" = "#2f5d8c",
    "Official subgroup" = "#1b9e77",
    "Sensitivity" = "#7570b3",
    "Official sensitivity" = "#d95f02"
  )) +
  labs(
    title = "Dynamic ATT across main and sensitivity specifications",
    subtitle = "Points are dynamic ATT estimates; horizontal bars are approximate 95% confidence intervals.",
    x = "Dynamic ATT"
  ) +
  theme_cs(11)

ggsave(file.path(report_dir, "key_dynamic_att_forest.png"), p_forest, width = 9, height = 5.8, dpi = 220)

balanced <- tibble::tribble(
  ~spec, ~family, ~e12, ~e24, ~e36, ~e48,
  "Main: not-yet", "Main", 0.1063, 0.1896, 0.2665, 0.3438,
  "Official yes", "Official subgroup", 0.1036, 0.2214, 0.3210, 0.4278,
  "Official no", "Official subgroup", 0.1069, 0.1783, 0.2461, 0.3139,
  "Never-treated only", "Sensitivity", 0.0734, 0.1599, 0.2365, 0.3145,
  "G>=13 pre12", "Sensitivity", 0.0760, 0.1556, 0.2183, 0.2856,
  "G<12 subgroup", "Sensitivity", 0.0457, 0.1383, 0.2321, 0.3336,
  "G>=12 subgroup", "Sensitivity", 0.0766, 0.1601, 0.2313, 0.3026,
  "Official yes + never", "Official sensitivity", 0.1029, 0.2222, 0.3228, 0.4261,
  "Official yes + G>=13 pre12", "Official sensitivity", 0.0912, 0.2090, 0.3041, 0.4079,
  "Official no + never", "Official sensitivity", 0.0583, 0.1337, 0.2005, 0.2707,
  "Official no + G>=13 pre12", "Official sensitivity", 0.0679, 0.1361, 0.1872, 0.2443
) %>%
  tidyr::pivot_longer(starts_with("e"), names_to = "horizon", values_to = "att") %>%
  mutate(
    horizon_num = as.integer(sub("e", "", horizon)),
    highlight = case_when(
      spec == "Main: not-yet" ~ "Main",
      grepl("^Official yes", spec) ~ "Official yes",
      grepl("^Official no", spec) ~ "Official no",
      TRUE ~ "Other sensitivity"
    )
  )

p_balanced <- ggplot(balanced, aes(x = horizon_num, y = att, group = spec)) +
  geom_line(aes(color = highlight, linewidth = highlight, alpha = highlight)) +
  geom_point(aes(color = highlight, alpha = highlight), size = 1.8) +
  scale_x_continuous(breaks = c(12, 24, 36, 48)) +
  scale_color_manual(values = c(
    "Main" = "#2f5d8c",
    "Official yes" = "#1b9e77",
    "Official no" = "#d95f02",
    "Other sensitivity" = "grey65"
  )) +
  scale_linewidth_manual(values = c("Main" = 1.1, "Official yes" = 1.1, "Official no" = 1.1, "Other sensitivity" = 0.55)) +
  scale_alpha_manual(values = c("Main" = 1, "Official yes" = 1, "Official no" = 1, "Other sensitivity" = 0.45)) +
  guides(linewidth = "none", alpha = "none") +
  labs(
    title = "Balanced dynamic ATT by post-event horizon",
    subtitle = "Estimates generally rise as the required post-event observation window becomes longer.",
    x = "Balanced event horizon",
    y = "ATT"
  ) +
  theme_cs(11)

ggsave(file.path(report_dir, "key_balanced_dynamic_paths.png"), p_balanced, width = 8.8, height = 5.2, dpi = 220)

pretrend <- tibble::tribble(
  ~spec, ~family, ~pre_cells, ~sig_cells, ~wald_p,
  "Main: not-yet", "Main", 7021, 886, 0,
  "Official yes", "Official subgroup", 6806, 1960, 0,
  "Official no", "Official subgroup", 7021, 1062, 0,
  "Never-treated only", "Sensitivity", 7140, 1052, 0,
  "G>=13 pre12", "Sensitivity", 7074, 652, 0,
  "G<12 subgroup", "Sensitivity", 55, 3, 0.3536,
  "G>=12 subgroup", "Sensitivity", 7085, 897, 0,
  "Official yes + never", "Official sensitivity", 6923, 1893, 0,
  "Official yes + G>=13 pre12", "Official sensitivity", 6857, 1929, 0,
  "Official no + never", "Official sensitivity", 7140, 1194, 0,
  "Official no + G>=13 pre12", "Official sensitivity", 7074, 804, 0
) %>%
  mutate(
    sig_share = sig_cells / pre_cells,
    spec = factor(spec, levels = rev(spec)),
    label = paste0(sig_cells, "/", pre_cells)
  )

p_pretrend <- ggplot(pretrend, aes(x = sig_share, y = spec, fill = family)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = label), hjust = -0.06, size = 3.1, color = "grey20") +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1), limits = c(0, max(pretrend$sig_share) * 1.18)) +
  scale_fill_manual(values = c(
    "Main" = "#2f5d8c",
    "Official subgroup" = "#1b9e77",
    "Sensitivity" = "#7570b3",
    "Official sensitivity" = "#d95f02"
  )) +
  labs(
    title = "Share of significant pre-trend cells",
    subtitle = "Official-guidance specifications show substantially stronger pre-event differences.",
    x = "Pointwise significant pre-trend cells / all pre-trend cells"
  ) +
  theme_cs(11)

ggsave(file.path(report_dir, "key_pretrend_significant_share.png"), p_pretrend, width = 9, height = 5.8, dpi = 220)

message("Saved key figures to: ", report_dir)
