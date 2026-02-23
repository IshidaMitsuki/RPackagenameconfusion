"""
GitHub同名リポジトリ作成を基準としたイベントスタディ分析 (2×3分類 / 30日刻み版)

- 対象   : timing_category == '後から同名あり' パッケージ
- t=0    : GitHub同名（非公式）リポジトリ最初の作成時点
- t<0    : 出現前, t>0: 出現後
- 時間軸 : period (30日bin) 基準。overlay_data_2x3.json の period 列を使用
           period_from_github = period - github_period
           where github_period = (github_date - first_dl_date).days // 30

入力:
  overlay_data_2x3.json
  output/packages_classified_2x3.csv  (first_nonofficial_date, First_Download_Date 使用)

出力:
  figures/event_study/ 以下の PNG
"""

import json
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib
matplotlib.use('Agg')
from matplotlib.ticker import FuncFormatter
from pathlib import Path
import matplotlib.font_manager as fm
import platform

# ===== 日本語フォント =====
def setup_japanese_font():
    if platform.system() == 'Windows':
        candidates = ['Yu Gothic', 'Meiryo', 'MS Gothic']
    elif platform.system() == 'Darwin':
        candidates = ['Hiragino Sans', 'Hiragino Kaku Gothic ProN']
    else:
        candidates = ['Noto Sans CJK JP', 'IPAGothic']
    available = {f.name for f in fm.fontManager.ttflist}
    for font in candidates:
        if font in available:
            matplotlib.rcParams['font.family'] = font
            print(f"フォント設定: {font}")
            return
    print("警告: 日本語フォントが見つかりません")

setup_japanese_font()
matplotlib.rcParams['axes.unicode_minus'] = False

# ===== パス =====
BASE_DIR       = Path(__file__).parent
INPUT_JSON     = BASE_DIR / "overlay_data_2x3.json"
CLASSIFIED_CSV = BASE_DIR / "output" / "packages_classified_2x3.csv"
OUTPUT_DIR     = BASE_DIR / "figures" / "event_study"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ===== カラー =====
OFFICIAL_COLORS = {
    '公式へ誘導あり': '#1f77b4',
    '公式へ誘導なし': '#ff7f0e',
}

# ===== データ読み込み =====
print("=" * 80)
print("GitHub同名作成イベントスタディ分析 (30日刻み版)")
print("=" * 80)
print()

# 分類 CSV（後から同名ありのみ使用）
print("分類 CSV 読み込み中...")
cls_df = pd.read_csv(
    CLASSIFIED_CSV,
    usecols=['Package', 'official_category', 'timing_category',
             'first_nonofficial_date', 'First_Download_Date']
)
aftercran_df = cls_df[cls_df['timing_category'] == '後から同名あり'].copy()
aftercran_df['first_nonofficial_date'] = pd.to_datetime(aftercran_df['first_nonofficial_date'], utc=True).dt.tz_localize(None)
aftercran_df['First_Download_Date']    = pd.to_datetime(aftercran_df['First_Download_Date'])

print(f"  後から同名あり: {len(aftercran_df):,} パッケージ")
print(f"  公式へ誘導あり: {(aftercran_df['official_category']=='公式へ誘導あり').sum():,}")
print(f"  公式へ誘導なし: {(aftercran_df['official_category']=='公式へ誘導なし').sum():,}")

# overlay_data_2x3.json
print()
print("overlay_data_2x3.json 読み込み中...")
with open(INPUT_JSON, 'r', encoding='utf-8') as f:
    raw_data = json.load(f)
print(f"  読み込み完了: {len(raw_data)} カテゴリ")

# ===== GitHub出現 period の計算 =====
# github_period = (first_nonofficial_date - First_Download_Date).days // 30
print()
print("GitHub出現 period を計算中...")

pkg2github_period = {}
skipped = 0
for _, row in aftercran_df.iterrows():
    pkg     = row['Package']
    gh_date = row['first_nonofficial_date']
    dl_date = row['First_Download_Date']
    if pd.isna(gh_date) or pd.isna(dl_date):
        skipped += 1
        continue
    days_diff = (gh_date - dl_date).days
    pkg2github_period[pkg] = days_diff // 30

print(f"  計算完了: {len(pkg2github_period):,} パッケージ  (スキップ: {skipped})")

# ===== period_from_github を計算してイベントスタディデータ構築 =====
print()
print("イベントスタディデータ構築中...")

event_data = {
    '公式へ誘導あり': [],
    '公式へ誘導なし': [],
}

pkg2official = aftercran_df.set_index('Package')['official_category'].to_dict()

for official_label in ['公式へ誘導あり', '公式へ誘導なし']:
    cat_key = f"{official_label}_後から同名あり"
    if cat_key not in raw_data:
        print(f"  警告: {cat_key} が JSON に見つかりません")
        continue

    packages = raw_data[cat_key]
    count = 0
    for pkg, records in packages.items():
        if not records:
            continue
        if pkg not in pkg2github_period:
            continue

        gh_period = pkg2github_period[pkg]
        df = pd.DataFrame(records)
        df['period_from_github'] = df['period'] - gh_period
        event_data[official_label].append(df[['period_from_github', 'Downloads']])
        count += 1

    print(f"  {official_label}: {count:,} パッケージ収集")

total_pkgs = sum(len(v) for v in event_data.values())
print(f"  合計: {total_pkgs:,} パッケージ")

# ===== サンプル数分析（X軸カットオフ）=====
print()
print("サンプル数分析中...")
all_frames = []
for frames in event_data.values():
    all_frames.extend(frames)

if all_frames:
    combined_all = pd.concat(all_frames, ignore_index=True)
    period_counts = combined_all.groupby('period_from_github').size()
    max_cnt  = period_counts.max()
    thresh   = max_cnt * 0.5
    valid_ps = sorted(period_counts[period_counts >= thresh].index.tolist())
    min_p = min(valid_ps) if valid_ps else None
    max_p = max(valid_ps) if valid_ps else None
    print(f"  最大サンプル数: {max_cnt:,}  50%閾値: {thresh:.0f}")
    print(f"  50%以上の範囲: period {min_p} ~ {max_p}")

# ===== グラフ描画ユーティリティ =====
def fmt_y(y, _):
    return '{:,.0f}'.format(y)

def add_event_line(ax):
    ax.axvline(x=0, color='red', linestyle='--', linewidth=2.5,
               label='GitHub同名作成時点', alpha=0.7)

def finalize_ax(ax, title, log_scale=False, xlim=None):
    ax.set_xlabel('GitHub同名作成からの経過期間（30日刻み）', fontsize=14)
    ax.set_ylabel('月別ダウンロード数', fontsize=14)
    if log_scale:
        ax.set_yscale('log')
        ax.yaxis.set_major_formatter(FuncFormatter(fmt_y))
    ax.set_title(title, fontsize=14, fontweight='bold')
    if xlim is not None:
        ax.set_xlim(xlim)
    ax.legend(fontsize=13, loc='best')
    ax.grid(True, alpha=0.3)
    ax.tick_params(axis='both', which='major', labelsize=13)

def save(fig, name):
    path = OUTPUT_DIR / f"{name}.png"
    plt.tight_layout()
    fig.savefig(path, dpi=300, bbox_inches='tight')
    plt.close(fig)
    print(f"  保存: {path.name}")

# ===== [1] 2分類比較（全期間）=====
print()
print("=" * 80)
print("[1] 2分類比較グラフ（全期間・対数スケール）")
print("=" * 80)

fig, ax = plt.subplots(figsize=(14, 8))
for label, frames in event_data.items():
    if not frames:
        continue
    combined = pd.concat(frames, ignore_index=True)
    med = combined.groupby('period_from_github')['Downloads'].median().reset_index()
    ax.plot(med['period_from_github'], med['Downloads'],
            linewidth=3, color=OFFICIAL_COLORS[label],
            label=f'{label} (n={len(frames)})', marker='o', markersize=4, alpha=0.85)
add_event_line(ax)
finalize_ax(ax, 'GitHub同名作成前後のダウンロード推移（2分類比較）')
save(fig, 'event_study_2categories')

# ===== [2] 全体統合（全期間）=====
print()
print("[2] 全体統合グラフ（全期間）")
if all_frames:
    fig, ax = plt.subplots(figsize=(14, 8))
    med = combined_all.groupby('period_from_github')['Downloads'].median().reset_index()
    ax.plot(med['period_from_github'], med['Downloads'],
            linewidth=3, color='#2ca02c',
            label=f'全体中央値 (n={total_pkgs})', marker='o', markersize=5)
    add_event_line(ax)
    finalize_ax(ax, 'GitHub同名作成前後のダウンロード推移（全体統合）')
    save(fig, 'event_study_all')

# ===== [3] 各分類個別 =====
print()
print("[3] 各分類個別グラフ")
for label, frames in event_data.items():
    if not frames:
        continue
    fig, ax = plt.subplots(figsize=(14, 8))
    combined = pd.concat(frames, ignore_index=True)
    med = combined.groupby('period_from_github')['Downloads'].median().reset_index()
    ax.plot(med['period_from_github'], med['Downloads'],
            linewidth=3, color=OFFICIAL_COLORS[label],
            label=f'中央値 (n={len(frames)})', marker='o', markersize=5)
    add_event_line(ax)
    finalize_ax(ax, f'GitHub同名作成前後のダウンロード推移（{label}）')
    safe = label.replace('/', '_')
    save(fig, f'event_study_{safe}')

# ===== [4] ズーム版 (±24/48/60/72 periods) 2分類比較 =====
print()
print("[4] ズーム版グラフ（2分類比較）")
for zoom in [24, 48, 60, 72]:
    fig, ax = plt.subplots(figsize=(14, 8))
    for label, frames in event_data.items():
        if not frames:
            continue
        combined = pd.concat(frames, ignore_index=True)
        zoomed = combined[(combined['period_from_github'] >= -zoom) &
                          (combined['period_from_github'] <=  zoom)]
        med = zoomed.groupby('period_from_github')['Downloads'].median().reset_index()
        ax.plot(med['period_from_github'], med['Downloads'],
                linewidth=3, color=OFFICIAL_COLORS[label],
                label=f'{label} (n={len(frames)})', marker='o', markersize=4, alpha=0.85)
    add_event_line(ax)
    finalize_ax(ax,
        f'GitHub同名作成前後のダウンロード推移（2分類比較・±{zoom} periods）',
        xlim=(-zoom, zoom))
    save(fig, f'event_study_2categories_zoom{zoom}p')

# ===== [5] ズーム版 全体統合 =====
print()
print("[5] ズーム版グラフ（全体統合）")
for zoom in [24, 48]:
    if not all_frames:
        continue
    fig, ax = plt.subplots(figsize=(14, 8))
    zoomed = combined_all[(combined_all['period_from_github'] >= -zoom) &
                          (combined_all['period_from_github'] <=  zoom)]
    med = zoomed.groupby('period_from_github')['Downloads'].median().reset_index()
    ax.plot(med['period_from_github'], med['Downloads'],
            linewidth=3, color='#2ca02c',
            label=f'全体中央値 (n={total_pkgs})', marker='o', markersize=5)
    add_event_line(ax)
    finalize_ax(ax,
        f'GitHub同名作成前後のダウンロード推移（全体・±{zoom} periods）',
        xlim=(-zoom, zoom))
    save(fig, f'event_study_all_zoom{zoom}p')

# ===== [6] 自動カット版 (50%サンプル範囲) =====
print()
print("[6] 自動カット版（50%サンプル範囲）")
if min_p is not None and max_p is not None:
    fig, ax = plt.subplots(figsize=(14, 8))
    for label, frames in event_data.items():
        if not frames:
            continue
        combined = pd.concat(frames, ignore_index=True)
        zoomed = combined[(combined['period_from_github'] >= min_p) &
                          (combined['period_from_github'] <= max_p)]
        med = zoomed.groupby('period_from_github')['Downloads'].median().reset_index()
        ax.plot(med['period_from_github'], med['Downloads'],
                linewidth=3, color=OFFICIAL_COLORS[label],
                label=f'{label} (n={len(frames)})', marker='o', markersize=4, alpha=0.85)
    add_event_line(ax)
    finalize_ax(ax,
        f'GitHub同名作成前後のダウンロード推移（2分類比較・端カット {min_p}~{max_p}）',
        xlim=(min_p, max_p))
    save(fig, 'event_study_2categories_autocut')

# ===== 完了 =====
print()
print("=" * 80)
print("イベントスタディ分析完了")
print("=" * 80)
png_files = sorted(OUTPUT_DIR.glob("*.png"))
print(f"出力先: {OUTPUT_DIR}")
print(f"生成ファイル数: {len(png_files)}")
for f in png_files:
    size_kb = f.stat().st_size / 1024
    print(f"  [{size_kb:6.0f} KB] {f.name}")
