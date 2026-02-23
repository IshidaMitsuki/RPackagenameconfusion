"""
2×3分類オーバーレイグラフ作成スクリプト
入力: overlay_data_2x3.json
出力: figures/ 以下の各PNGファイル

グラフ種類:
1. 6カテゴリ個別オーバーレイ（中央値線のみ）× 6
2. 全6カテゴリ重ね合わせ（中央値6本線）
3. 公式誘導あり vs なし（2本線）
4. タイミング3種比較（カット版 + フル版）
5. 各公式誘導内でタイミング別比較 × 2
"""

import json
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib
matplotlib.use('Agg')
from pathlib import Path

# ===== 日本語フォント設定 =====
import matplotlib.font_manager as fm
import platform

def setup_japanese_font():
    """日本語フォントを設定する"""
    if platform.system() == 'Windows':
        candidates = ['Yu Gothic', 'Meiryo', 'MS Gothic', 'TakaoGothic']
    elif platform.system() == 'Darwin':
        candidates = ['Hiragino Sans', 'Hiragino Kaku Gothic ProN']
    else:
        candidates = ['Noto Sans CJK JP', 'IPAGothic', 'VL Gothic']
    
    available = [f.name for f in fm.fontManager.ttflist]
    for font in candidates:
        if font in available:
            matplotlib.rcParams['font.family'] = font
            print(f"フォント設定: {font}")
            return font
    print("警告: 日本語フォントが見つかりません（文字化けの可能性あり）")
    return None

setup_japanese_font()
matplotlib.rcParams['axes.unicode_minus'] = False

# ===== パス設定 =====
BASE_DIR = Path(__file__).parent
INPUT_JSON = BASE_DIR / "overlay_data_2x3.json"
OUTPUT_DIR = BASE_DIR / "figures"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ===== カテゴリ定義 =====
OFFICIAL_LABELS = ['公式へ誘導あり', '公式へ誘導なし']
TIMING_LABELS   = ['既に同名あり', '後から同名あり', '同名なし']

# 6カテゴリキー（JSONのキーと一致）
CAT_KEYS = [
    '公式へ誘導あり_既に同名あり',
    '公式へ誘導あり_後から同名あり',
    '公式へ誘導あり_同名なし',
    '公式へ誘導なし_既に同名あり',
    '公式へ誘導なし_後から同名あり',
    '公式へ誘導なし_同名なし',
]

# ===== カラー設定 =====
# 6カテゴリ: 公式あり=青系（濃→中→薄）, 公式なし=橙系（濃→中→薄）
COLORS_6 = {
    '公式へ誘導あり_既に同名あり':  '#1f77b4',  # 濃青
    '公式へ誘導あり_後から同名あり': '#4d9fcf',  # 中青
    '公式へ誘導あり_同名なし':      '#aec7e8',  # 薄青
    '公式へ誘導なし_既に同名あり':  '#ff7f0e',  # 濃橙
    '公式へ誘導なし_後から同名あり': '#ffaa44',  # 中橙
    '公式へ誘導なし_同名なし':      '#ffbb78',  # 薄橙
}

# 線スタイル：タイミングで区別
LINESTYLES = {
    '既に同名あり':  '-',   # 実線
    '後から同名あり': '--',  # 破線
    '同名なし':      ':',   # 点線
}

MARKERS = {
    '既に同名あり':  'o',
    '後から同名あり': 's',
    '同名なし':      '^',
}

OFFICIAL_COLORS = {
    '公式へ誘導あり': '#1f77b4',
    '公式へ誘導なし': '#ff7f0e',
}

TIMING_COLORS = {
    '既に同名あり':  '#1f77b4',
    '後から同名あり': '#ff7f0e',
    '同名なし':      '#2ca02c',
}

# ===== データ読み込み =====
print("=" * 80)
print("overlay_data_2x3.json 読み込み中...")
print("=" * 80)

with open(INPUT_JSON, 'r', encoding='utf-8') as f:
    raw_data = json.load(f)

print(f"読み込み完了: {len(raw_data)} カテゴリ")
for key, pkgs in raw_data.items():
    print(f"  {key}: {len(pkgs)} パッケージ")

# ===== ヘルパー関数 =====

def get_median_series(packages_data: dict) -> pd.DataFrame | None:
    """パッケージデータ辞書から period別中央値を計算"""
    frames = []
    for pkg, records in packages_data.items():
        if records is None or len(records) == 0:
            continue
        df = pd.DataFrame(records)
        frames.append(df)
    if not frames:
        return None
    combined = pd.concat(frames, ignore_index=True)
    median_data = combined.groupby('period')['Downloads'].median().reset_index()
    return median_data


def get_sample_counts_by_period(packages_data: dict) -> dict:
    """各 period のサンプル数（行数）を返す"""
    frames = []
    for pkg, records in packages_data.items():
        if records is None or len(records) == 0:
            continue
        df = pd.DataFrame(records)
        frames.append(df)
    if not frames:
        return {}
    combined = pd.concat(frames, ignore_index=True)
    return combined.groupby('period').size().to_dict()


def calc_x_cutoff(sample_counts: dict, threshold_ratio: float = 0.5) -> int | None:
    """サンプル数が最大値の threshold_ratio 以上の最大 period を返す"""
    if not sample_counts:
        return None
    max_count = max(sample_counts.values())
    threshold = max_count * threshold_ratio
    valid = sorted([p for p, c in sample_counts.items() if c >= threshold])
    return max(valid) if valid else None


def finalize_plot(ax, xlabel='初回公開からの経過期間（30日刻み）',
                  ylabel='月別ダウンロード数', title='', log_scale=True,
                  fontsize_axis=14, fontsize_title=14):
    ax.set_xlabel(xlabel, fontsize=fontsize_axis)
    ax.set_ylabel(ylabel, fontsize=fontsize_axis)
    if log_scale:
        ax.set_yscale('log')
    ax.set_title(title, fontsize=fontsize_title, fontweight='bold')
    ax.legend(fontsize=11, loc='best', ncol=2)
    ax.grid(True, alpha=0.3)
    ax.tick_params(axis='both', which='major', labelsize=12)


# ===== グラフ1: 6カテゴリ個別オーバーレイ（中央値のみ）=====
print()
print("=" * 80)
print("[1/5] 6カテゴリ個別オーバーレイグラフ（中央値線）作成")
print("=" * 80)

for cat_key in CAT_KEYS:
    if cat_key not in raw_data or len(raw_data[cat_key]) == 0:
        print(f"  スキップ（データなし）: {cat_key}")
        continue

    packages_data = raw_data[cat_key]
    n_pkgs = len(packages_data)

    median_data = get_median_series(packages_data)
    if median_data is None:
        print(f"  スキップ（中央値計算失敗）: {cat_key}")
        continue

    color = COLORS_6.get(cat_key, '#333333')
    safe_filename = cat_key.replace('/', '_').replace(' ', '_')

    fig, ax = plt.subplots(figsize=(14, 8))
    ax.plot(median_data['period'], median_data['Downloads'],
            linewidth=2.5, color=color, label=f'{cat_key} (n={n_pkgs})',
            marker='o', markersize=4, alpha=0.9)

    title = f'{cat_key}\n中央値推移（n={n_pkgs}パッケージ）'
    finalize_plot(ax, title=title, log_scale=True)

    out_path = OUTPUT_DIR / f"overlay_individual_{safe_filename}.png"
    plt.tight_layout()
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    plt.close()
    print(f"  保存: {out_path.name}")


# ===== グラフ2: 全6カテゴリ重ね合わせ（中央値6本線）=====
print()
print("=" * 80)
print("[2/5] 全6カテゴリ重ね合わせ（中央値6本線）作成")
print("=" * 80)

fig, ax = plt.subplots(figsize=(16, 10))
total_pkgs = 0

for cat_key in CAT_KEYS:
    if cat_key not in raw_data or len(raw_data[cat_key]) == 0:
        continue

    packages_data = raw_data[cat_key]
    n_pkgs = len(packages_data)
    total_pkgs += n_pkgs

    median_data = get_median_series(packages_data)
    if median_data is None:
        continue

    # タイミング部分を取り出す
    parts = cat_key.split('_', 1)  # ['公式へ誘導あり', '同名なし'] 等
    official_part = parts[0]
    timing_part   = parts[1] if len(parts) > 1 else ''

    color = COLORS_6.get(cat_key, '#333333')
    ls    = LINESTYLES.get(timing_part, '-')
    mk    = MARKERS.get(timing_part, 'o')
    label = f'{cat_key} (n={n_pkgs})'

    ax.plot(median_data['period'], median_data['Downloads'],
            linewidth=2.5, color=color, linestyle=ls, label=label,
            marker=mk, markersize=4, alpha=0.85)

title = f'全6カテゴリ 中央値比較（2分類×3タイミング）\n総パッケージ数: {total_pkgs}'
finalize_plot(ax, title=title, log_scale=True, fontsize_axis=14, fontsize_title=15)

out_path = OUTPUT_DIR / "overlay_all6categories.png"
plt.tight_layout()
plt.savefig(out_path, dpi=300, bbox_inches='tight')
plt.close()
print(f"  保存: {out_path.name}")


# ===== グラフ3: 公式誘導あり vs なし（2本線）=====
print()
print("=" * 80)
print("[3/5] 公式誘導あり vs なし（2本線：全タイミング統合）作成")
print("=" * 80)

fig, ax = plt.subplots(figsize=(14, 8))
total_pkgs = 0

for official_label in OFFICIAL_LABELS:
    frames = []
    n_pkgs = 0

    for cat_key in CAT_KEYS:
        if not cat_key.startswith(official_label):
            continue
        if cat_key not in raw_data:
            continue
        packages_data = raw_data[cat_key]
        n_pkgs += len(packages_data)
        for pkg, records in packages_data.items():
            if records:
                frames.append(pd.DataFrame(records))

    if not frames:
        continue

    total_pkgs += n_pkgs
    combined = pd.concat(frames, ignore_index=True)
    median_data = combined.groupby('period')['Downloads'].median().reset_index()

    color = OFFICIAL_COLORS[official_label]
    label = f'{official_label} (n={n_pkgs})'
    ax.plot(median_data['period'], median_data['Downloads'],
            linewidth=3, color=color, label=label,
            marker='o', markersize=5, alpha=0.85)

title = f'公式誘導あり vs なし 中央値比較（全タイミング統合）\n総パッケージ数: {total_pkgs}'
finalize_plot(ax, title=title, log_scale=True, fontsize_axis=14, fontsize_title=14)
ax.legend(fontsize=13, loc='best', ncol=1)

out_path = OUTPUT_DIR / "overlay_2categories.png"
plt.tight_layout()
plt.savefig(out_path, dpi=300, bbox_inches='tight')
plt.close()
print(f"  保存: {out_path.name}")


# ===== グラフ4: タイミング3種比較（カット版 + フル版）=====
print()
print("=" * 80)
print("[4/5] タイミング3種比較（全分類統合）カット版 + フル版 作成")
print("=" * 80)

timing_median_data = {}
all_sample_counts  = {}
total_pkgs = 0

for timing_label in TIMING_LABELS:
    frames = []
    n_pkgs = 0

    for cat_key in CAT_KEYS:
        if not cat_key.endswith(timing_label):
            continue
        if cat_key not in raw_data:
            continue
        packages_data = raw_data[cat_key]
        n_pkgs += len(packages_data)
        for pkg, records in packages_data.items():
            if records:
                frames.append(pd.DataFrame(records))

    if not frames:
        continue

    total_pkgs += n_pkgs
    combined = pd.concat(frames, ignore_index=True)

    # サンプル数記録
    for period, cnt in combined.groupby('period').size().items():
        all_sample_counts[period] = all_sample_counts.get(period, 0) + cnt

    median_data = combined.groupby('period')['Downloads'].median().reset_index()
    timing_median_data[timing_label] = {'data': median_data, 'count': n_pkgs}

# X軸カットオフ計算（全タイミング合算のサンプル数ベース）
x_cutoff = calc_x_cutoff(all_sample_counts, threshold_ratio=0.5)
print(f"  X軸カットオフ: period <= {x_cutoff}  (最大サンプルの50%以上の範囲)")

# ---- 4a: カット版 ----
fig, ax = plt.subplots(figsize=(14, 8))
for timing_label in TIMING_LABELS:
    if timing_label not in timing_median_data:
        continue
    info = timing_median_data[timing_label]
    color = TIMING_COLORS[timing_label]
    label = f'{timing_label} (n={info["count"]})'
    ax.plot(info['data']['period'], info['data']['Downloads'],
            linewidth=3, color=color, label=label,
            marker='s', markersize=5, alpha=0.85)

if x_cutoff is not None:
    ax.set_xlim(0, x_cutoff)

title = f'タイミング別中央値比較（全分類統合・端カット）\n総パッケージ数: {total_pkgs}'
ax.set_xlabel('初回公開からの経過期間（30日刻み）', fontsize=14)
ax.set_ylabel('月別ダウンロード数', fontsize=14)
ax.set_title(title, fontsize=14, fontweight='bold')
ax.legend(fontsize=13, loc='best')
ax.grid(True, alpha=0.3)
ax.tick_params(axis='both', which='major', labelsize=13)

out_path = OUTPUT_DIR / "overlay_3timings_cut.png"
plt.tight_layout()
plt.savefig(out_path, dpi=300, bbox_inches='tight')
plt.close()
print(f"  保存（カット版）: {out_path.name}")

# ---- 4b: フル版 ----
fig, ax = plt.subplots(figsize=(14, 8))
for timing_label in TIMING_LABELS:
    if timing_label not in timing_median_data:
        continue
    info = timing_median_data[timing_label]
    color = TIMING_COLORS[timing_label]
    label = f'{timing_label} (n={info["count"]})'
    ax.plot(info['data']['period'], info['data']['Downloads'],
            linewidth=3, color=color, label=label,
            marker='s', markersize=5, alpha=0.85)

title = f'タイミング別中央値比較（全分類統合・全期間）\n総パッケージ数: {total_pkgs}'
ax.set_xlabel('初回公開からの経過期間（30日刻み）', fontsize=14)
ax.set_ylabel('月別ダウンロード数', fontsize=14)
ax.set_title(title, fontsize=14, fontweight='bold')
ax.legend(fontsize=13, loc='best')
ax.grid(True, alpha=0.3)
ax.tick_params(axis='both', which='major', labelsize=13)

out_path = OUTPUT_DIR / "overlay_3timings_full.png"
plt.tight_layout()
plt.savefig(out_path, dpi=300, bbox_inches='tight')
plt.close()
print(f"  保存（フル版）: {out_path.name}")

# ---- 4c: ログスケール版（カット）----
fig, ax = plt.subplots(figsize=(14, 8))
for timing_label in TIMING_LABELS:
    if timing_label not in timing_median_data:
        continue
    info = timing_median_data[timing_label]
    color = TIMING_COLORS[timing_label]
    label = f'{timing_label} (n={info["count"]})'
    ax.plot(info['data']['period'], info['data']['Downloads'],
            linewidth=3, color=color, label=label,
            marker='s', markersize=5, alpha=0.85)

if x_cutoff is not None:
    ax.set_xlim(0, x_cutoff)

ax.set_yscale('log')
title = f'タイミング別中央値比較（全分類統合・端カット・対数スケール）\n総パッケージ数: {total_pkgs}'
ax.set_xlabel('初回公開からの経過期間（30日刻み）', fontsize=14)
ax.set_ylabel('月別ダウンロード数（対数スケール）', fontsize=14)
ax.set_title(title, fontsize=14, fontweight='bold')
ax.legend(fontsize=13, loc='best')
ax.grid(True, alpha=0.3, which='both')
ax.tick_params(axis='both', which='major', labelsize=13)

out_path = OUTPUT_DIR / "overlay_3timings_cut_log.png"
plt.tight_layout()
plt.savefig(out_path, dpi=300, bbox_inches='tight')
plt.close()
print(f"  保存（ログスケール版）: {out_path.name}")


# ===== グラフ5: 各公式誘導内タイミング別比較 × 2 =====
print()
print("=" * 80)
print("[5/5] 各公式誘導内タイミング別比較グラフ作成")
print("=" * 80)

for official_label in OFFICIAL_LABELS:
    fig, ax = plt.subplots(figsize=(14, 8))
    has_data = False
    total_pkgs = 0

    sample_cnts = {}

    for timing_label in TIMING_LABELS:
        cat_key = f"{official_label}_{timing_label}"
        if cat_key not in raw_data or len(raw_data[cat_key]) == 0:
            print(f"  スキップ（データなし）: {cat_key}")
            continue

        packages_data = raw_data[cat_key]
        n_pkgs = len(packages_data)
        total_pkgs += n_pkgs

        median_data = get_median_series(packages_data)
        if median_data is None:
            continue

        has_data = True
        color = TIMING_COLORS[timing_label]
        label = f'{timing_label} (n={n_pkgs})'
        ax.plot(median_data['period'], median_data['Downloads'],
                linewidth=3, color=color, label=label,
                marker='s', markersize=5, alpha=0.85)

    if has_data:
        ax.set_yscale('log')
        title = f'{official_label} - タイミング別中央値比較\n総パッケージ数: {total_pkgs}'
        ax.set_xlabel('初回公開からの経過期間（30日刻み）', fontsize=14)
        ax.set_ylabel('月別ダウンロード数（対数スケール）', fontsize=14)
        ax.set_title(title, fontsize=14, fontweight='bold')
        ax.legend(fontsize=12, loc='best')
        ax.grid(True, alpha=0.3, which='both')
        ax.tick_params(axis='both', which='major', labelsize=13)

        safe = official_label.replace('/', '_').replace(' ', '_')
        out_path = OUTPUT_DIR / f"overlay_timing_in_{safe}.png"
        plt.tight_layout()
        plt.savefig(out_path, dpi=300, bbox_inches='tight')
        plt.close()
        print(f"  保存: {out_path.name}")
    else:
        plt.close()
        print(f"  {official_label}: データなし、スキップ")


# ===== 完了サマリ =====
print()
print("=" * 80)
print("グラフ作成完了")
print("=" * 80)
output_files = sorted(OUTPUT_DIR.glob("*.png"))
print(f"出力先: {OUTPUT_DIR}")
print(f"生成ファイル数: {len(output_files)}")
for f in output_files:
    size_kb = f.stat().st_size / 1024
    print(f"  [{size_kb:6.0f} KB] {f.name}")
