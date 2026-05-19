# Create figures for the official-before-event CS2021 DID v8 report.

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(scales)
})

args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args, value = TRUE)
script_path <- if (length(file_arg) > 0) {
  sub("^--file=", "", file_arg[1])
} else {
  file.path(getwd(), "analysis", "make_cs2021_v8_official_before_report_figures.R")
}
script_path <- normalizePath(script_path, winslash = "/", mustWork = FALSE)
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE)
if (!dir.exists(file.path(base_dir, "figures"))) {
  base_dir <- normalizePath(file.path(getwd(), "RPackagenameconfusion"), winslash = "/", mustWork = FALSE)
}

out_dir <- file.path(base_dir, "figures", "cs2021_did_r_v8")
report_dir <- file.path(out_dir, "report_official_before")
if (!dir.exists(report_dir)) dir.create(report_dir, recursive = TRUE)

theme_report <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      plot.title = element_text(face = "bold", size = base_size + 2),
      plot.subtitle = element_text(color = "grey35"),
      legend.position = "bottom",
      legend.title = element_blank()
    )
}

att_results <- tibble::tribble(
  ~spec, ~family, ~treated, ~dynamic_att, ~dynamic_se, ~group_att, ~group_se, ~calendar_att, ~calendar_se,
  "Main: all treated", "Main", 3262, 0.3569, 0.0192, 0.3128, 0.0174, 0.2975, 0.0169,
  "Main subgroup: official before yes", "Main subgroup", 852, 0.4268, 0.0458, 0.3749, 0.0396, 0.3721, 0.0387,
  "Main subgroup: official before no", "Main subgroup", 2410, 0.3454, 0.0206, 0.3014, 0.0187, 0.2851, 0.0183,
  "Sensitivity: never-treated only", "Sensitivity", 3262, 0.3664, 0.0189, 0.3212, 0.0168, 0.3077, 0.0180,
  "Sensitivity: G>=13 pre12", "Sensitivity", 2712, 0.3257, 0.0206, 0.2779, 0.0181, 0.2757, 0.0177,
  "Sensitivity: G<12 subgroup", "Sensitivity", 502, 0.4132, 0.0485, 0.4132, 0.0460, 0.4171, 0.0442,
  "Sensitivity: G>=12 subgroup", "Sensitivity", 2760, 0.3476, 0.0207, 0.2973, 0.0188, 0.3006, 0.0188,
  "Official before yes + never", "Official-before sensitivity", 852, 0.4315, 0.0439, 0.3788, 0.0420, 0.3770, 0.0394,
  "Official before yes + G>=13 pre12", "Official-before sensitivity", 699, 0.3895, 0.0481, 0.3302, 0.0433, 0.3108, 0.0411,
  "Official before no + never", "Official-before sensitivity", 2410, 0.3553, 0.0204, 0.3102, 0.0182, 0.2963, 0.0197,
  "Official before no + G>=13 pre12", "Official-before sensitivity", 2013, 0.3233, 0.0220, 0.2749, 0.0194, 0.2763, 0.0190
) %>%
  mutate(
    ci_low = dynamic_att - 1.96 * dynamic_se,
    ci_high = dynamic_att + 1.96 * dynamic_se,
    spec = factor(spec, levels = rev(spec))
  )

p_forest <- ggplot(att_results, aes(x = dynamic_att, y = spec, color = family)) +
  geom_vline(xintercept = 0, color = "grey72", linewidth = 0.4) +
  geom_errorbarh(aes(xmin = ci_low, xmax = ci_high), height = 0, linewidth = 0.75) +
  geom_point(size = 2.5) +
  scale_color_manual(values = c(
    "Main" = "#2b5c8a",
    "Main subgroup" = "#20815f",
    "Sensitivity" = "#7359a5",
    "Official-before sensitivity" = "#c46825"
  )) +
  labs(
    title = "Dynamic ATT across main and sensitivity specifications",
    subtitle = "Official-before groups use official guidance observed before the nonofficial same-name event.",
    x = "Dynamic ATT"
  ) +
  theme_report(11)

ggsave(file.path(report_dir, "official_before_dynamic_att_forest.png"), p_forest, width = 9.5, height = 6.0, dpi = 220)

balanced <- tibble::tribble(
  ~spec, ~family, ~e12, ~e24, ~e36, ~e48,
  "Main: all treated", "Main", 0.0682, 0.1512, 0.2253, 0.3016,
  "Main subgroup: official before yes", "Main subgroup", 0.0837, 0.1892, 0.2747, 0.3663,
  "Main subgroup: official before no", "Main subgroup", 0.0615, 0.1406, 0.2124, 0.2879,
  "Sensitivity: never-treated only", "Sensitivity", 0.0727, 0.1585, 0.2344, 0.3116,
  "Sensitivity: G>=13 pre12", "Sensitivity", 0.0753, 0.1541, 0.2164, 0.2829,
  "Sensitivity: G<12 subgroup", "Sensitivity", 0.0456, 0.1376, 0.2310, 0.3319,
  "Sensitivity: G>=12 subgroup", "Sensitivity", 0.0757, 0.1584, 0.2291, 0.2996,
  "Official before yes + never", "Official-before sensitivity", 0.0855, 0.1926, 0.2799, 0.3719,
  "Official before yes + G>=13 pre12", "Official-before sensitivity", 0.0633, 0.1669, 0.2472, 0.3396,
  "Official before no + never", "Official-before sensitivity", 0.0669, 0.1486, 0.2217, 0.2980,
  "Official before no + G>=13 pre12", "Official-before sensitivity", 0.0788, 0.1549, 0.2135, 0.2775
) %>%
  pivot_longer(starts_with("e"), names_to = "horizon", values_to = "att") %>%
  mutate(
    horizon = as.integer(sub("e", "", horizon)),
    highlight = case_when(
      spec == "Main: all treated" ~ "Main",
      grepl("official before yes", spec, ignore.case = TRUE) ~ "Official before yes",
      grepl("official before no", spec, ignore.case = TRUE) ~ "Official before no",
      TRUE ~ "Other sensitivity"
    )
  )

p_balanced <- ggplot(balanced, aes(x = horizon, y = att, group = spec)) +
  geom_line(aes(color = highlight, linewidth = highlight, alpha = highlight)) +
  geom_point(aes(color = highlight, alpha = highlight), size = 1.9) +
  scale_x_continuous(breaks = c(12, 24, 36, 48)) +
  scale_color_manual(values = c(
    "Main" = "#2b5c8a",
    "Official before yes" = "#20815f",
    "Official before no" = "#c46825",
    "Other sensitivity" = "grey62"
  )) +
  scale_linewidth_manual(values = c("Main" = 1.1, "Official before yes" = 1.1, "Official before no" = 1.1, "Other sensitivity" = 0.55)) +
  scale_alpha_manual(values = c("Main" = 1, "Official before yes" = 1, "Official before no" = 1, "Other sensitivity" = 0.48)) +
  guides(linewidth = "none", alpha = "none") +
  labs(
    title = "Balanced dynamic ATT by post-event horizon",
    subtitle = "Each point restricts the sample to packages observed through that post-event horizon.",
    x = "Balanced event horizon",
    y = "ATT"
  ) +
  theme_report(11)

ggsave(file.path(report_dir, "official_before_balanced_dynamic_paths.png"), p_balanced, width = 9.0, height = 5.2, dpi = 220)

pretrend <- tibble::tribble(
  ~spec, ~family, ~pre_cells, ~sig_cells, ~wald_p,
  "Main: all treated", "Main", 7140, 879, 0,
  "Main subgroup: official before yes", "Main subgroup", 6923, 1963, 0,
  "Main subgroup: official before no", "Main subgroup", 7140, 1030, 0,
  "Sensitivity: never-treated only", "Sensitivity", 7140, 1061, 0,
  "Sensitivity: G>=13 pre12", "Sensitivity", 7074, 659, 0,
  "Sensitivity: G<12 subgroup", "Sensitivity", 55, 3, 0.4443,
  "Sensitivity: G>=12 subgroup", "Sensitivity", 7085, 890, 0,
  "Official before yes + never", "Official-before sensitivity", 6923, 1865, 0,
  "Official before yes + G>=13 pre12", "Official-before sensitivity", 6857, 1899, 0,
  "Official before no + never", "Official-before sensitivity", 7140, 1217, 0,
  "Official before no + G>=13 pre12", "Official-before sensitivity", 7074, 840, 0
) %>%
  mutate(
    sig_share = sig_cells / pre_cells,
    label = paste0(sig_cells, "/", pre_cells),
    spec = factor(spec, levels = rev(spec))
  )

p_pretrend <- ggplot(pretrend, aes(x = sig_share, y = spec, fill = family)) +
  geom_col(width = 0.72) +
  geom_text(aes(label = label), hjust = -0.06, size = 3.0, color = "grey20") +
  scale_x_continuous(labels = percent_format(accuracy = 1), limits = c(0, max(pretrend$sig_share) * 1.18)) +
  scale_fill_manual(values = c(
    "Main" = "#2b5c8a",
    "Main subgroup" = "#20815f",
    "Sensitivity" = "#7359a5",
    "Official-before sensitivity" = "#c46825"
  )) +
  labs(
    title = "Share of significant pre-trend cells",
    subtitle = "Official-before-yes specifications have the strongest pre-event differences.",
    x = "Pointwise significant pre-trend cells / all pre-trend cells"
  ) +
  theme_report(11)

ggsave(file.path(report_dir, "official_before_pretrend_significant_share.png"), p_pretrend, width = 9.5, height = 6.0, dpi = 220)

message("Saved figures to: ", report_dir)
