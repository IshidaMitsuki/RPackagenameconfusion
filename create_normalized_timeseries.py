"""
正規化時系列データ生成スクリプト (2×3分類用)

cran_monthly_downloads_from_first.csv を使用する。
このファイルは fetch_monthly_downloads.py で生成されたもので、
各パッケージの実際の初回DL日(First_Download_Date)を t=0 として
30日刻みでDL数が集計済み。

  Period=0 → 初回DL日から最初の30日間
  Period=1 → 31〜60日目
  ...

日付計算は不要。Period 列がそのまま時系列の軸になる。

入力:
- packages_classified_2x3.csv : パッケージ分類データ (2×3)
- ../cran_monthly_downloads_from_first.csv : 30日刻みDLデータ

出力:
- overlay_data_2x3.json : 6カテゴリ別の時系列データ
  形式: {category_key: {package: [{period: x, Downloads: y}, ...]}}

特徴:
- 定期保存・再開機能付き (SAVE_INTERVAL 件ごと)
- OneDrive同期時の PermissionError リトライ機能付き
"""

import json
import time
from datetime import datetime
from pathlib import Path

import pandas as pd

# ── パス設定 ─────────────────────────────────────
# SCRIPT_DIR = .../Analy_senkou/reorganized/
# RNOMI_DIR  = .../Rnomi/
SCRIPT_DIR = Path(__file__).parent
RNOMI_DIR  = SCRIPT_DIR.parent.parent   # Analy_senkou の親 = Rnomi

CLASSIFIED_FILE = SCRIPT_DIR / 'output' / 'packages_classified_2x3.csv'
FROM_FIRST_FILE = RNOMI_DIR  / 'cran_monthly_downloads_from_first.csv'   # 30日刻みDLデータ

OUTPUT_FILE   = SCRIPT_DIR / 'overlay_data_2x3.json'
PROGRESS_FILE = SCRIPT_DIR / 'timeseries_progress_2x3.json'

SAVE_INTERVAL = 500   # 定期保存間隔（パッケージ数）

# ── 保存・再開ユーティリティ ──────────────────────

def _save_json_with_retry(obj, path, max_retries=5):
    """OneDrive 同期時の PermissionError に対応したリトライ付き保存"""
    for attempt in range(max_retries):
        try:
            with open(path, 'w', encoding='utf-8') as f:
                json.dump(obj, f, indent=2, ensure_ascii=False)
            return True
        except PermissionError:
            if attempt < max_retries - 1:
                print(f"  保存失敗（試行{attempt+1}/{max_retries}）、3秒後リトライ...")
                time.sleep(3)
            else:
                print(f"  警告: {path} の保存に失敗しました（OneDrive同期中の可能性）")
                return False

def load_progress():
    if PROGRESS_FILE.exists():
        with open(PROGRESS_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}

def save_progress(progress):
    _save_json_with_retry(progress, PROGRESS_FILE)

def load_overlay_data():
    """既存の出力ファイルを読み込む（再開用）"""
    if OUTPUT_FILE.exists():
        print(f"既存データを読み込んでいます: {OUTPUT_FILE}")
        with open(OUTPUT_FILE, 'r', encoding='utf-8') as f:
            raw = json.load(f)
        result = {}
        for cat_key, packages in raw.items():
            result[cat_key] = {}
            for pkg, records in packages.items():
                if records:
                    result[cat_key][pkg] = pd.DataFrame(records)
        total_pkgs = sum(len(v) for v in result.values())
        print(f"  読み込み完了: {len(result)} カテゴリ, {total_pkgs} パッケージ")
        return result
    return {}

def save_overlay_data(overlay_data):
    """DataFrame を list-of-dicts に変換して保存"""
    data = {}
    for cat_key, packages in overlay_data.items():
        data[cat_key] = {}
        for pkg, df in packages.items():
            if df is not None and len(df) > 0:
                data[cat_key][pkg] = df.to_dict('records')
    _save_json_with_retry(data, OUTPUT_FILE)

# ── メイン処理 ────────────────────────────────────

def load_data():
    print("データを読み込んでいます...")

    # 分類データ（カテゴリ情報だけ使用）
    classified = pd.read_csv(CLASSIFIED_FILE, usecols=['Package', 'official_category', 'timing_category'])
    classified['category_key'] = classified['official_category'] + '_' + classified['timing_category']
    print(f"  分類データ: {len(classified)} パッケージ")

    # 30日刻みDLデータ（Period=0 が実際の初回DL日を基準とした t=0）
    from_first = pd.read_csv(FROM_FIRST_FILE, usecols=['Package', 'Period', 'Downloads'])
    print(f"  30日刻みDLデータ (読み込み): {len(from_first):,} 行 ({from_first['Package'].nunique():,} パッケージ)")

    # fetch_monthly_downloads.py の複数回実行による重複行を除去
    # （同一 Package+Period は同値なので最初の1行を残す）
    before = len(from_first)
    from_first = from_first.drop_duplicates(subset=['Package', 'Period'], keep='first')
    removed = before - len(from_first)
    if removed > 0:
        print(f"  重複除去: {removed:,} 行削除 → {len(from_first):,} 行")

    return classified, from_first


def build_normalized_data(classified, from_first, overlay_data, processed_packages):
    """
    カテゴリ別に時系列データを構築。
    from_first の Period 列がそのまま t=0,1,2,... になる。
    """
    print("\n時系列データを構築しています...")

    # from_first を Package 単位で事前グループ化
    print("  インデックス化中...")
    dl_grouped = {
        pkg: grp[['Period', 'Downloads']].reset_index(drop=True)
        for pkg, grp in from_first.groupby('Package')
    }

    # データ収集時点の末尾 30日bin は期間が満たない可能性があるため除去
    # （各パッケージの max(Period) の行を削除）
    trimmed_count = 0
    for pkg in dl_grouped:
        df = dl_grouped[pkg]
        if len(df) > 1:
            dl_grouped[pkg] = df[df['Period'] < df['Period'].max()].reset_index(drop=True)
            trimmed_count += 1
    print(f"  最終 period 除去: {trimmed_count:,} パッケージで末尾 period を削除")

    print(f"  インデックス化完了: {len(dl_grouped)} パッケージ")

    total          = len(classified)
    new_count      = 0
    no_data_count  = 0
    resume_skip    = len(processed_packages)  # 今回実行開始時点で既処理済みの数
    last_save      = len(processed_packages)

    for idx, row in enumerate(classified.itertuples(), 1):
        package = row.Package
        cat_key = row.category_key

        if package in processed_packages:
            continue

        if cat_key not in overlay_data:
            overlay_data[cat_key] = {}

        if package in dl_grouped:
            df = dl_grouped[package].rename(columns={'Period': 'period'})
            if len(df) > 0:
                overlay_data[cat_key][package] = df
                new_count += 1
            else:
                no_data_count += 1
        else:
            no_data_count += 1

        processed_packages.add(package)

        if idx % 500 == 0:
            print(f"  処理中: {idx:,}/{total:,} ({new_count} 件追加)")

        if len(processed_packages) - last_save >= SAVE_INTERVAL:
            save_progress({'processed_packages': list(processed_packages),
                           'last_update': datetime.now().isoformat()})
            save_overlay_data(overlay_data)
            last_save = len(processed_packages)
            print(f"  → 定期保存: {len(processed_packages):,} パッケージ処理済み")

    print(f"\n構築完了: 新規追加 {new_count} 件, DLデータなし {no_data_count} 件, 再開スキップ {resume_skip} 件")
    print("\nカテゴリ別パッケージ数:")
    for cat in sorted(overlay_data.keys()):
        print(f"  {cat}: {len(overlay_data[cat])} パッケージ")

    return overlay_data, processed_packages


def main():
    print("=" * 60)
    print("正規化時系列データ生成 (2×3分類 / 30日刻み)")
    print("=" * 60)

    classified, from_first = load_data()

    overlay_data       = load_overlay_data()
    progress           = load_progress()
    processed_packages = set(progress.get('processed_packages', []))
    print(f"再開情報: {len(processed_packages):,} パッケージ処理済み")

    overlay_data, processed_packages = build_normalized_data(
        classified, from_first, overlay_data, processed_packages
    )

    print("\n最終保存中...")
    save_progress({'processed_packages': list(processed_packages),
                   'last_update': datetime.now().isoformat(),
                   'completed': True})
    save_overlay_data(overlay_data)

    print("\n" + "=" * 60)
    print("処理完了!")
    print("=" * 60)
    if OUTPUT_FILE.exists():
        size_mb = OUTPUT_FILE.stat().st_size / (1024 * 1024)
        print(f"出力: {OUTPUT_FILE}  ({size_mb:.2f} MB)")


if __name__ == '__main__':
    main()
