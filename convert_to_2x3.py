#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
既存の分類結果を2x3分類に変換
- 既存: category_2（公式可能性2分類） + timing_category（タイミング3分類）
- 新規: official_category（2分類） + timing_category（3分類）を明確化
"""

import pandas as pd
from pathlib import Path

# ベースディレクトリ
BASE_DIR = Path(r"C:\Users\mitsuki\OneDrive - 信州大学\kenkyu\R\Rdata\Rnomi")
SCRIPT_DIR = BASE_DIR / "Analy_senkou" / "reorganized"
OUTPUT_DIR = SCRIPT_DIR / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

print("=" * 80)
print("既存分類データの2x3変換")
print("=" * 80)
print()

# 既存の分類データを読み込み
print("既存分類データを読み込んでいます...")
df = pd.read_csv(BASE_DIR / "Analy_senkou" / "all_packages_classified_2categories.csv")
print(f"  総パッケージ数: {len(df):,}")
print()

# カラム名の変換マップ
category_2_map = {
    '1_公式可能性高': '公式へ誘導あり',
    '2_公式なし': '公式へ誘導なし'
}

timing_map = {
    'CRAN前': '既に同名あり',
    'CRAN後': '後から同名あり',
    'CRAN前後なし': '同名なし'
}

# カテゴリを変換
df['official_category'] = df['category_2'].map(category_2_map)
df['timing_category_new'] = df['timing_category'].map(timing_map)

# timing_category_newをtiming_categoryに上書き
df['timing_category'] = df['timing_category_new']
df = df.drop(columns=['category_2', 'timing_category_new'])

print("=" * 80)
print("2x3クロス集計")
print("=" * 80)
print()

# クロス集計
cross_tab = pd.crosstab(
    df['official_category'],
    df['timing_category'],
    margins=True,
    margins_name='合計'
)

print(cross_tab)
print()

# パーセンテージ表示
print("割合（%）:")
cross_tab_pct = pd.crosstab(
    df['official_category'],
    df['timing_category'],
    normalize='all'
) * 100

print(cross_tab_pct.round(1))
print()

# CSV保存
print("=" * 80)
print("CSV保存")
print("=" * 80)
print()

output_csv = OUTPUT_DIR / "packages_classified_2x3.csv"
df.to_csv(output_csv, index=False, encoding='utf-8-sig')
print(f"保存完了: {output_csv}")
print()

# サマリーCSV
summary_data = []
for official_cat in ['公式へ誘導あり', '公式へ誘導なし']:
    for timing_cat in ['既に同名あり', '後から同名あり', '同名なし']:
        count = len(df[
            (df['official_category'] == official_cat) &
            (df['timing_category'] == timing_cat)
        ])
        pct = count / len(df) * 100
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

# カテゴリ別パッケージリスト出力
print("=" * 80)
print("カテゴリ別パッケージリスト出力")
print("=" * 80)
print()

category_dir = OUTPUT_DIR / "categories"
category_dir.mkdir(exist_ok=True)

for official_cat in ['公式へ誘導あり', '公式へ誘導なし']:
    for timing_cat in ['既に同名あり', '後から同名あり', '同名なし']:
        filtered = df[
            (df['official_category'] == official_cat) &
            (df['timing_category'] == timing_cat)
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
print("変換完了")
print("=" * 80)
