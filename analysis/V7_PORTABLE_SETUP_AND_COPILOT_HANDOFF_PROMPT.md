# CS2021 v7 Portable Setup and Copilot Handoff Prompt

This note is for running CS2021 DiD v7 in a new environment with minimal ambiguity.

## 1) Scope

Target script:
- analysis/cs2021_did_v7.R

Expected direct inputs:
- overlay_data_2x3.json
- output/packages_classified_2x3.csv

Main output root:
- figures/cs2021_did_r

## 2) Required software

- R x64 (recommended: R 4.4.x)
- R packages: did, jsonlite
- (Optional for data regeneration) Python 3.10+ and pandas

## 3) Required source files for regenerating 2x3 data

To regenerate the two required input files, the following source files are needed:

- data/package_first_download_dates.csv
- data/cran_monthly_downloads_from_first.csv
- ../../r_repo_details_part1.json  (resolved from reorganized root)
- ../../r_repo_details_part2.json  (resolved from reorganized root)
- ../../../cran_official_packages.csv (resolved from reorganized root)

## 4) Regenerate input files on a new machine

Run from reorganized root directory:

1. Build package classification CSV (2x3):
- python classify_packages_2x3.py

Expected output:
- output/packages_classified_2x3.csv

2. Build normalized overlay JSON:
- python create_normalized_timeseries.py

Expected output:
- overlay_data_2x3.json

## 5) Run v7 (main estimation)

Run from analysis directory. Use x64 Rscript explicitly.

PowerShell example:

$env:CS2021_DEBUG_TAG = "main"
$env:CS2021_DIAG_ONLY = "0"
$env:CS2021_SKIP_DIAGNOSTICS = "1"
& "C:\Program Files\R\R-4.4.1\bin\x64\Rscript.exe" .\cs2021_did_v7.R

Current v7 is mostly fixed-profile and only these 3 environment variables are expected for routine operation.

## 6) Success criteria

Do not judge success only by process exit code.

Check figures/cs2021_did_r/run_progress.log for the latest run segment:

Success markers (both expected):
- [overall] ATT(g,t):
- [overall] summary report saved

Failure markers (any means failed):
- [overall] main ... failed
- [overall] 全推定失敗: スキップ

## 7) Notes on memory

Known issue on weak-memory environments:
- cannot allocate vector (for example 670.4 Mb)

If this occurs repeatedly, use a machine with larger RAM and rerun with the same fixed profile.

---

# Copilot Handoff Prompt (copy and paste)

Use the following prompt in another environment:

You are continuing CS2021 DiD v7 execution in this repository.

Goal:
- Regenerate required 2x3 inputs if missing
- Run analysis/cs2021_did_v7.R main estimation once
- Judge success by run_progress.log markers, not by exit code only

Constraints:
- Do not change estimand defaults in cs2021_did_v7.R
- Keep biters=999 and control_group profile as defined by script
- Use x64 Rscript
- Do not run subgroup A/B/C until main success is confirmed

Tasks:
1) Verify file existence:
- overlay_data_2x3.json
- output/packages_classified_2x3.csv
- analysis/cs2021_did_v7.R

2) If missing, regenerate inputs from reorganized root:
- python classify_packages_2x3.py
- python create_normalized_timeseries.py

3) Run main once from analysis:
- set CS2021_DEBUG_TAG=main
- set CS2021_DIAG_ONLY=0
- set CS2021_SKIP_DIAGNOSTICS=1
- execute x64 Rscript on cs2021_did_v7.R

4) Report:
- latest run log segment from run_progress.log
- explicit success/failure verdict for main
- reason based on success/failure markers

5) If failed due memory allocation:
- do not silently claim success
- report exact allocation error line and stop before A/B/C
