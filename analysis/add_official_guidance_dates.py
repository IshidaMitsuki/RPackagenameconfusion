"""Add first official-guidance repository dates to packages_classified_2x3.csv.

This helper avoids pandas so it can run in the lightweight Python environment
available on the research machine.  It mirrors classify_packages_2x3.py's
package-specific CRAN URL rule for official guidance.
"""

from __future__ import annotations

import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
CLASSIFIED_CSV = PROJECT_DIR / "output" / "packages_classified_2x3.csv"
REPO_PARTS = [
    PROJECT_DIR / "r_repo_details_part1.json",
    PROJECT_DIR / "r_repo_details_part2.json",
]


def load_github_data() -> dict:
    out = {}
    for path in REPO_PARTS:
        with path.open("r", encoding="utf-8") as f:
            out.update(json.load(f))
    return out


def repo_text(repo: dict) -> str:
    parts = []
    for key in ("description", "readme_content", "readme"):
        val = repo.get(key)
        if isinstance(val, str):
            parts.append(val)
    key_files = repo.get("key_files_content")
    if isinstance(key_files, dict):
        parts.extend(v for v in key_files.values() if isinstance(v, str))
    elif isinstance(key_files, str):
        parts.append(key_files)
    return "\n".join(parts)


def has_package_url(repo: dict, package: str) -> bool:
    if not repo or not package:
        return False
    pkg = re.escape(package)
    patterns = [
        rf"https?://cran\.r-project\.org/package={pkg}\b",
        rf"https?://cran\.r-project\.org/web/packages/{pkg}/index\.html\b",
        rf"https?://rdrr\.io/cran/{pkg}\b",
        rf"https?://www\.rdocumentation\.org/packages/{pkg}\b",
    ]
    text = repo_text(repo)
    return bool(text and any(re.search(pat, text, flags=re.IGNORECASE) for pat in patterns))


def parse_created_at(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


def main() -> None:
    github_data = load_github_data()

    with CLASSIFIED_CSV.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fieldnames = list(reader.fieldnames or [])

    if "first_official_guidance_date" not in fieldnames:
        fieldnames.append("first_official_guidance_date")

    for idx, row in enumerate(rows, start=1):
        package = row.get("Package", "")
        repos = github_data.get(package, {}).get("repositories", [])
        first_dt = None
        for repo in repos:
            if not has_package_url(repo, package):
                continue
            created = parse_created_at(repo.get("created_at"))
            if created is not None and (first_dt is None or created < first_dt):
                first_dt = created
        row["first_official_guidance_date"] = "" if first_dt is None else first_dt.strftime("%Y-%m-%d %H:%M:%S")
        if idx % 1000 == 0:
            print(f"processed {idx}/{len(rows)}")

    with CLASSIFIED_CSV.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    n_guidance = sum(1 for row in rows if row.get("first_official_guidance_date"))
    print(f"updated {CLASSIFIED_CSV}")
    print(f"first_official_guidance_date nonmissing: {n_guidance:,}/{len(rows):,}")


if __name__ == "__main__":
    main()
