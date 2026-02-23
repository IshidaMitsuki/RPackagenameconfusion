# Reorganized Analysis - 2×3分類による整理済み分析

**作成日**: 2026年2月20日  
**目的**: 辞書分類を削除し、公式誘導×タイミングの2×3分類に統一

## ディレクトリ構造

```
reorganized/
├── README.md                          # このファイル
├── 研究サマリー.md                       # 研究の全体像と主要な発見
├── classify_packages_2x3.py           # パッケージ分類スクリプト（元データ生成用）
├── convert_to_2x3.py                  # 既存分類からの変換スクリプト
├── integrate_data.py                  # データ統合スクリプト
├── analyze_by_category.py             # カテゴリ別分析スクリプト
├── visualize_categories.py            # 可視化スクリプト
├── output/                            # 分類データと統計
│   ├── packages_classified_2x3.csv    # 2×3分類データ（22,781パッケージ）
│   ├── packages_integrated_with_downloads.csv  # DL数統合データ（24,352パッケージ）
│   ├── classification_summary_2x3.csv # 分類サマリー
│   ├── download_statistics_by_category.csv  # カテゴリ別DL統計
│   └── categories/                    # カテゴリ別パッケージリスト（6個のCSV）
├── analysis/                          # 分析結果
│   ├── category_download_statistics.csv      # カテゴリ別詳細統計
│   ├── monthly_downloads_by_category.csv     # 月次時系列データ（954行）
│   └── period_statistics_by_category.csv     # 期間別統計（144行）
└── figures/                           # 可視化図表
    ├── violin_plot_log.png            # ヴァイオリンプロット（対数）
    ├── violin_plot_linear.png         # ヴァイオリンプロット（実数）
    ├── boxplot_log.png                # ボックスプロット（対数）
    └── median_comparison.png          # 中央値比較棒グラフ
```

## 分類体系

### 2×3分類

| 次元 | カテゴリ | 説明 |
|------|---------|------|
| **公式誘導** (2) | 公式へ誘導あり | DESCRIPTIONに公式GitHubリンクあり |
| | 公式へ誘導なし | 公式GitHubリンクなし |
| **タイミング** (3) | 既に同名あり | CRAN公開前に同名GitHubリポジトリ存在 |
| | 後から同名あり | CRAN公開後に同名GitHubリポジトリ出現 |
| | 同名なし | 同名GitHubリポジトリなし |

合計: **6カテゴリ**

## 実行方法

### 1. データ統合
```bash
python integrate_data.py
```
- 分類データと初出日データを統合
- カテゴリ別の基本統計を計算

### 2. カテゴリ別分析
```bash
python analyze_by_category.py
```
- カレンダー月別DL数の読み込み
- 各パッケージの月別平均DL数の中央値を計算
- 初出後30日刻みの期間別分析
- カテゴリ別時系列データ作成

### 3. 可視化
```bash
python visualize_categories.py
```
- ヴァイオリンプロット（対数・実数）
- ボックスプロット
- 中央値比較棒グラフ

## 主要な発見

### カテゴリ別月別平均DL数（中央値）

| 公式誘導 | タイミング | パッケージ数 | 中央値 |
|---------|-----------|-------------|--------|
| 公式へ誘導あり | 後から同名あり | 1,700 | **629** |
| 公式へ誘導なし | 後から同名あり | 2,343 | 359 |
| 公式へ誘導あり | 同名なし | 10,186 | 327 |
| 公式へ誘導あり | 既に同名あり | 2,183 | 325 |
| 公式へ誘導なし | 同名なし | 5,684 | 291 |
| 公式へ誘導なし | 既に同名あり | 2,256 | 257 |

### 主要な洞察

1. **公式誘導の効果**: 公式へのGitHub誘導があると、月別平均DL数（中央値）が1.3～2.4倍に増加

2. **タイミングの影響**: 「後から同名あり」が最も高い中央値（629 vs 257-327）
   - 人気が出てから模倣者が現れるパターン
   - すでに確立されたパッケージは模倣者の影響を受けにくい

3. **中央値の意義**: 総DL数では少数の超人気パッケージが支配的だが、中央値で見ると典型的なパッケージの実態が把握できる

## データファイル

### 入力データ（上位ディレクトリから）
- `../all_packages_classified_2categories.csv`: 元の分類データ
- `../../cran_monthly_downloads.csv`: カレンダー月別DL数（180万行）
- `../../cran_monthly_downloads_from_first.csv`: 初出から30日刻みDL数
- `../../package_first_download_dates.csv`: 初出日データ（24,352パッケージ）

### 出力データ
- **分類データ**: `output/packages_classified_2x3.csv`
- **統合データ**: `output/packages_integrated_with_downloads.csv`
- **分析結果**: `analysis/` 配下の各CSVファイル
- **図表**: `figures/` 配下のPNGファイル

## 変更履歴

### 2026年2月20日
- 辞書分類（有り/無し）を削除
- 2×3＝6カテゴリに統一
- 月別平均DL数の中央値を主要指標として採用
- 新しいデータ構造でreorganizedディレクトリ作成
- 可視化スクリプトを新データ構造に対応

## 関連ドキュメント

- **研究サマリー**: `研究サマリー.md` - 研究の全体像、主要な発見、データファイル一覧
- **元の分析**: `../Analy_senkou/` - 辞書分類を含む詳細な分析（参考用）

## 注意事項

- このディレクトリの分析は**辞書分類を除外**した2×3分類に基づく
- 月別平均DL数は各パッケージの**中央値**を使用（外れ値の影響を軽減）
- 全てのパスは絶対パスで記述（環境依存を最小化）
