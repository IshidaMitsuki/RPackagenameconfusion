#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
パッケージ分類スクリプト（2x3分類）
- 公式可能性: 2分類（公式へ誘導あり / 公式へ誘導なし）
- タイミング: 3分類（既に同名あり / 後から同名あり / 同名なし）
- 辞書の有無による分類は廃止
"""

import pandas as pd
import json
import re
from pathlib import Path
from datetime import datetime

# ベースディレクトリ
BASE_DIR = Path(r"C:\Users\mitsuki\OneDrive - 信州大学\kenkyu\R\Rdata\Rnomi")
SCRIPT_DIR = BASE_DIR / "Analy_senkou" / "reorganized"
OUTPUT_DIR = SCRIPT_DIR / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

print("=" * 80)
print("パッケージ分類（2x3分類）")
print("=" * 80)
print()

# データ読み込み
print("データを読み込んでいます...")

# CRANパッケージデータ（既存のダウンロードデータから取得）
DOWNLOAD_CSV = BASE_DIR / "cran_monthly_downloads copy.csv"
df_downloads = pd.read_csv(DOWNLOAD_CSV)

# パッケージリストを作成（Published, Actual_First_Publicationはダウンロードデータから推定）
df_packages = pd.DataFrame({
    'Package': df_downloads['Package'].unique()
})

# 最初の出現月を Published として設定
first_pub = df_downloads.groupby('Package')['Month'].min().reset_index()
first_pub.columns = ['Package', 'Published']
df_packages = df_packages.merge(first_pub, on='Package', how='left')
df_packages['Published'] = pd.to_datetime(df_packages['Published'])
df_packages['Actual_First_Publication'] = df_packages['Published']  # 実質的な初回公開日として使用
df_packages['Published'] = pd.to_datetime(df_packages['Published'])
df_packages['Actual_First_Publication'] = df_packages['Published']  # 実質的な初回公開日として使用

# GitHubデータ
RDATA_DIR = Path(r"c:\Users\mitsuki\OneDrive - 信州大学\kenkyu\R\Rdata")
with open(RDATA_DIR / "r_repo_details_part1.json", 'r', encoding='utf-8') as f:
    github_data_1 = json.load(f)
with open(RDATA_DIR / "r_repo_details_part2.json", 'r', encoding='utf-8') as f:
    github_data_2 = json.load(f)
github_data = {**github_data_1, **github_data_2}

# 公式リポジトリリスト
OFFICIAL_PACKAGES_CSV = Path(r"c:\Users\mitsuki\OneDrive - 信州大学\kenkyu\R\cran_official_packages.csv")
official_df = pd.read_csv(OFFICIAL_PACKAGES_CSV)
official_repos_set = set()
for _, row in official_df.iterrows():
    url = row.get('Official_GitHub', '')
    if pd.notna(url) and url:
        match = re.search(r'github\.com/([^/]+)/([^/#?]+)', url)
        if match:
            owner, repo = match.groups()
            repo = repo.rstrip('.git')
            full_name = f"{owner}/{repo}".lower()
            official_repos_set.add(full_name)

print(f"  CRANパッケージ数: {len(df_packages):,}")
print(f"  GitHubデータ: {len(github_data):,}パッケージ")
print(f"  公式リポジトリ数: {len(official_repos_set):,}")
print()

# パッケージ固有のCRAN URL検出関数
def find_package_url_in_text(repo_info, package_name):
    """GitHub側のテキストからパッケージ固有のCRAN URLを検出"""
    if not repo_info or not package_name:
        return False

    pkg = re.escape(package_name)
    patterns = [
        rf'https?://cran\.r-project\.org/package={pkg}\b',
        rf'https?://cran\.r-project\.org/web/packages/{pkg}/index\.html\b',
        rf'https?://rdrr\.io/cran/{pkg}\b',
        rf'https?://www\.rdocumentation\.org/packages/{pkg}\b'
    ]

    text_parts = []
    desc = repo_info.get('description')
    if isinstance(desc, str):
        text_parts.append(desc)

    readme = repo_info.get('readme_content') or repo_info.get('readme')
    if isinstance(readme, str):
        text_parts.append(readme)

    key_files = repo_info.get('key_files_content')
    if isinstance(key_files, dict):
        text_parts.extend([v for v in key_files.values() if isinstance(v, str)])
    elif isinstance(key_files, str):
        text_parts.append(key_files)

    combined = "\n".join(text_parts)
    if not combined:
        return False

    return any(re.search(pat, combined, flags=re.IGNORECASE) for pat in patterns)

# ========================================
# 1. 公式可能性の判定（2分類）
# ========================================
print("=" * 80)
print("1. 公式可能性の判定")
print("=" * 80)
print()

official_category_list = []

for idx, row in df_packages.iterrows():
    if (idx + 1) % 1000 == 0:
        print(f"  処理中: {idx + 1}/{len(df_packages)}")
    
    package = row['Package']
    
    if package not in github_data:
        official_category_list.append('公式へ誘導なし')
        continue
    
    repos = github_data[package].get('repositories', [])
    if not repos:
        official_category_list.append('公式へ誘導なし')
        continue
    
    # パッケージ固有のCRAN URLを記載したリポジトリがあるか
    has_package_url = False
    for repo in repos:
        if find_package_url_in_text(repo, package):
            has_package_url = True
            break
    
    if has_package_url:
        official_category_list.append('公式へ誘導あり')
    else:
        official_category_list.append('公式へ誘導なし')

df_packages['official_category'] = official_category_list

# カテゴリ別の集計
print("\n公式可能性カテゴリ別の集計:")
official_counts = df_packages['official_category'].value_counts()
for cat, count in official_counts.items():
    print(f"  {cat}: {count:,}件 ({count/len(df_packages)*100:.1f}%)")
print()

# ========================================
# 2. タイミング判定（3分類）
# ========================================
print("=" * 80)
print("2. タイミング判定")
print("=" * 80)
print()

timing_category_list = []

for idx, row in df_packages.iterrows():
    if (idx + 1) % 1000 == 0:
        print(f"  処理中: {idx + 1}/{len(df_packages)}")
    
    package = row['Package']
    actual_publication = row['Actual_First_Publication']
    
    if package not in github_data:
        timing_category_list.append('同名なし')
        continue
    
    repos = github_data[package].get('repositories', [])
    if not repos:
        timing_category_list.append('同名なし')
        continue
    
    has_before = False
    has_after = False
    
    for repo in repos:
        repo_full_name = repo.get('repo_full_name', '').lower()
        created_at = repo.get('created_at')
        
        if not created_at:
            continue
        
        # owner=cranを除外
        if '/' in repo_full_name:
            owner = repo_full_name.split('/')[0]
            if owner == 'cran':
                continue
        
        # 公式リポジトリを除外
        if repo_full_name in official_repos_set:
            continue
        
        # 該当パッケージのCRAN URLを記載したリポジトリを除外
        if find_package_url_in_text(repo, package):
            continue
        
        # 前後判定
        created = pd.to_datetime(created_at)
        if created.tz is not None:
            created = created.tz_localize(None)
        
        if created < actual_publication:
            has_before = True
        else:
            has_after = True
    
    if has_before:
        timing_category_list.append('既に同名あり')
    elif has_after:
        timing_category_list.append('後から同名あり')
    else:
        timing_category_list.append('同名なし')

df_packages['timing_category'] = timing_category_list

# タイミングカテゴリ別の集計
print("\nタイミングカテゴリ別の集計:")
timing_counts = df_packages['timing_category'].value_counts()
for cat, count in timing_counts.items():
    print(f"  {cat}: {count:,}件 ({count/len(df_packages)*100:.1f}%)")
print()

# ========================================
# 3. 2x3クロス集計
# ========================================
print("=" * 80)
print("3. 2x3クロス集計")
print("=" * 80)
print()

cross_tab = pd.crosstab(
    df_packages['official_category'],
    df_packages['timing_category'],
    margins=True,
    margins_name='合計'
)

print(cross_tab)
print()

# パーセンテージ表示
print("割合（%）:")
cross_tab_pct = pd.crosstab(
    df_packages['official_category'],
    df_packages['timing_category'],
    normalize='all'
) * 100

print(cross_tab_pct.round(1))
print()

# ========================================
# 4. CSV保存
# ========================================
print("=" * 80)
print("4. CSV保存")
print("=" * 80)
print()

output_csv = OUTPUT_DIR / "packages_classified_2x3.csv"
df_packages.to_csv(output_csv, index=False, encoding='utf-8-sig')
print(f"保存完了: {output_csv}")
print()

# サマリーCSV
summary_data = []
for official_cat in ['公式へ誘導あり', '公式へ誘導なし']:
    for timing_cat in ['既に同名あり', '後から同名あり', '同名なし']:
        count = len(df_packages[
            (df_packages['official_category'] == official_cat) &
            (df_packages['timing_category'] == timing_cat)
        ])
        pct = count / len(df_packages) * 100
        summary_data.append({
            '公式可能性': official_cat,
            'タイミング': timing_cat,
            'パッケージ数': count,
            '割合(%)': round(pct, 2)
        })

summary_df = pd.DataFrame(summary_data)
summary_csv = OUTPUT_DIR / "classification_summary_2x3.csv"
summary_df.to_csv(summary_csv, index=False, encoding='utf-8-sig')
print(f"サマリー保存完了: {summary_csv}")
print()

# ========================================
# 5. カテゴリ別パッケージリスト出力
# ========================================
print("=" * 80)
print("5. カテゴリ別パッケージリスト出力")
print("=" * 80)
print()

category_dir = OUTPUT_DIR / "categories"
category_dir.mkdir(exist_ok=True)

for official_cat in ['公式へ誘導あり', '公式へ誘導なし']:
    for timing_cat in ['既に同名あり', '後から同名あり', '同名なし']:
        filtered = df_packages[
            (df_packages['official_category'] == official_cat) &
            (df_packages['timing_category'] == timing_cat)
        ]
        
        if len(filtered) > 0:
            # ファイル名用に変換
            official_label = 'with_guidance' if official_cat == '公式へ誘導あり' else 'no_guidance'
            timing_label = {
                '既に同名あり': 'before_cran',
                '後から同名あり': 'after_cran',
                '同名なし': 'no_github'
            }[timing_cat]
            
            filename = f"{official_label}_{timing_label}.csv"
            filepath = category_dir / filename
            
            filtered[['Package', 'Published', 'Actual_First_Publication']].to_csv(
                filepath, index=False, encoding='utf-8-sig'
            )
            print(f"  {official_cat} × {timing_cat}: {len(filtered):,}件 → {filename}")

print()
print("=" * 80)
print("分類完了")
print("=" * 80)
