import pandas as pd
import requests
import time
import os
import datetime
from dateutil.relativedelta import relativedelta
from pathlib import Path

# ======== 設定 ========
# 相対パス設定
# data_collection/ -> reorganized/ -> Analy_senkou/ -> Rnomi/ -> Rdata/ -> R/
_SCRIPT_DIR            = Path(__file__).parent
_RNOMI_DIR             = _SCRIPT_DIR.parent.parent.parent
_R_DIR                 = _SCRIPT_DIR.parent.parent.parent.parent.parent

INPUT_CSV             = str(_R_DIR / "cran_official_packages.csv")
OUTPUT_CSV            = str(_RNOMI_DIR / "cran_monthly_downloads.csv")
OUTPUT_CSV_FROM_FIRST = str(_RNOMI_DIR / "cran_monthly_downloads_from_first.csv")
FIRST_DATE_CSV        = str(_RNOMI_DIR / "package_first_download_dates.csv")

START_DATE_DEFAULT = "2012-10-01"  # RStudio CRAN mirrorログ公開開始日（公式）
BATCH_SIZE = 10
SLEEP_TIME = 0.5
# ======================

def fetch_from_api(packages, start_date, end_date):
    """APIリクエストの実処理"""
    pkg_str = ",".join(packages)
    url = f"https://cranlogs.r-pkg.org/downloads/daily/{start_date}:{end_date}/{pkg_str}"
    try:
        r = requests.get(url, timeout=30)
        if r.status_code == 200:
            return r.json()
        return None
    except:
        return None

def process_api_data(data):
    """APIレスポンスをDataFrameに変換（カレンダー月次＋初出から30日刻み＋初出日記録）"""
    if not data: return None, None, None
    
    if isinstance(data, dict):
        if "error" in data: return None, None, None
        data = [data]
        
    all_monthly_calendar = []
    all_monthly_from_first = []
    first_dates = []
    
    for item in data:
        pkg_name = item.get('package')
        downloads = item.get('downloads')
        
        if not pkg_name or not downloads: continue
            
        df_daily = pd.DataFrame(downloads)
        if df_daily.empty: continue
            
        df_daily['day'] = pd.to_datetime(df_daily['day'])
        
        # 初出日を記録（ダウンロード数が0より大きい最初の日）
        df_with_downloads = df_daily[df_daily['downloads'] > 0]
        if df_with_downloads.empty: continue
        
        first_date = df_with_downloads['day'].min()
        first_dates.append({
            'Package': pkg_name,
            'First_Download_Date': first_date.strftime('%Y-%m-%d'),
            'First_Downloads': int(df_with_downloads[df_with_downloads['day'] == first_date]['downloads'].iloc[0])
        })
        
        # 1. カレンダー月別集計
        df_daily_indexed = df_daily.set_index('day')
        df_monthly_calendar = df_daily_indexed.resample('ME').sum()
        df_monthly_calendar['Package'] = pkg_name
        df_monthly_calendar.reset_index(inplace=True)
        df_monthly_calendar['Month'] = df_monthly_calendar['day'].dt.strftime('%Y-%m-01')
        df_monthly_calendar = df_monthly_calendar[['Package', 'Month', 'downloads']]
        df_monthly_calendar.rename(columns={'downloads': 'Downloads'}, inplace=True)
        all_monthly_calendar.append(df_monthly_calendar)
        
        # 2. 初出日から30日刻み集計
        df_from_first = df_daily[df_daily['day'] >= first_date].copy()
        df_from_first['days_from_first'] = (df_from_first['day'] - first_date).dt.days
        df_from_first['period'] = df_from_first['days_from_first'] // 30
        
        df_monthly_from_first = df_from_first.groupby('period').agg({
            'downloads': 'sum',
            'day': 'min'
        }).reset_index()
        df_monthly_from_first['Package'] = pkg_name
        df_monthly_from_first['Period_Start'] = df_monthly_from_first['day'].dt.strftime('%Y-%m-%d')
        df_monthly_from_first = df_monthly_from_first[['Package', 'period', 'Period_Start', 'downloads']]
        df_monthly_from_first.rename(columns={'period': 'Period', 'downloads': 'Downloads'}, inplace=True)
        all_monthly_from_first.append(df_monthly_from_first)
    
    df_calendar = pd.concat(all_monthly_calendar, ignore_index=True) if all_monthly_calendar else None
    df_from_first = pd.concat(all_monthly_from_first, ignore_index=True) if all_monthly_from_first else None
    df_first_dates = pd.DataFrame(first_dates) if first_dates else None
    
    return df_calendar, df_from_first, df_first_dates

def get_monthly_data_batch(packages, start_date="2012-10-01"):
    # 今日の日付を取得
    end_date = "2025-12-01"
    
    # 1. まずバッチで試す
    data = fetch_from_api(packages, start_date, end_date)
    
    if data:
        return process_api_data(data)
    
    # 2. 失敗したら個別に試す (404対策)
    print(f"   ⚠️ Batch failed. Retrying individually...")
    calendar_results = []
    from_first_results = []
    first_date_results = []
    
    for pkg in packages:
        data_single = fetch_from_api([pkg], start_date, end_date)
        df_calendar, df_from_first, df_first_dates = process_api_data(data_single)
        if df_calendar is not None:
            calendar_results.append(df_calendar)
        if df_from_first is not None:
            from_first_results.append(df_from_first)
        if df_first_dates is not None:
            first_date_results.append(df_first_dates)
        time.sleep(0.1) # 連打防止
    
    df_calendar_combined = pd.concat(calendar_results, ignore_index=True) if calendar_results else None
    df_from_first_combined = pd.concat(from_first_results, ignore_index=True) if from_first_results else None
    df_first_dates_combined = pd.concat(first_date_results, ignore_index=True) if first_date_results else None
    
    return df_calendar_combined, df_from_first_combined, df_first_dates_combined

def main():
    if not os.path.exists(INPUT_CSV):
        print("❌ Input CSV not found.")
        return

    os.makedirs(os.path.dirname(OUTPUT_CSV), exist_ok=True)

    print("📂 Loading package list...")
    df_pkgs = pd.read_csv(INPUT_CSV)
    all_packages = df_pkgs['Package'].dropna().unique().tolist()
    
    # 既に完全に取得済みのパッケージを特定（3つのファイル全てに存在し、データが十分あるもの）
    print("🔍 Checking existing data integrity...")
    
    calendar_pkgs = set()
    from_first_pkgs = set()
    first_date_pkgs = set()
    
    if os.path.exists(OUTPUT_CSV):
        try:
            df = pd.read_csv(OUTPUT_CSV)
            # 最低12ヶ月分のデータがあるパッケージのみ完全とみなす
            pkg_counts = df.groupby('Package').size()
            calendar_pkgs = set(pkg_counts[pkg_counts >= 12].index)
            print(f"   📊 Calendar data: {len(calendar_pkgs)} packages with sufficient data")
        except Exception as e:
            print(f"   ⚠️ Calendar data check failed: {e}")
    
    if os.path.exists(OUTPUT_CSV_FROM_FIRST):
        try:
            df = pd.read_csv(OUTPUT_CSV_FROM_FIRST)
            # 最低12期間分（約1年分）のデータがあるパッケージのみ完全とみなす
            pkg_counts = df.groupby('Package').size()
            from_first_pkgs = set(pkg_counts[pkg_counts >= 12].index)
            print(f"   🔢 From-first data: {len(from_first_pkgs)} packages with sufficient data")
        except Exception as e:
            print(f"   ⚠️ From-first data check failed: {e}")
    
    if os.path.exists(FIRST_DATE_CSV):
        try:
            df = pd.read_csv(FIRST_DATE_CSV)
            first_date_pkgs = set(df['Package'].unique())
            print(f"   📅 First date data: {len(first_date_pkgs)} packages with data")
        except Exception as e:
            print(f"   ⚠️ First date check failed: {e}")
    
    # 3つ全てに存在するパッケージのみを完全とみなす
    complete_pkgs = calendar_pkgs & from_first_pkgs & first_date_pkgs
    
    if complete_pkgs:
        print(f"✅ {len(complete_pkgs)} packages have complete data")
        incomplete_in_files = (calendar_pkgs | from_first_pkgs | first_date_pkgs) - complete_pkgs
        if incomplete_in_files:
            print(f"⚠️  {len(incomplete_in_files)} packages have incomplete data (will be re-fetched)")
        target_packages = [p for p in all_packages if p not in complete_pkgs]
    else:
        print("   No complete packages found. Starting fresh.")
        target_packages = all_packages
    
    # ヘッダー作成（存在しない場合のみ）
    if not os.path.exists(OUTPUT_CSV):
        with open(OUTPUT_CSV, 'w', encoding='utf-8') as f:
            f.write("Package,Month,Downloads\n")
    
    if not os.path.exists(OUTPUT_CSV_FROM_FIRST):
        with open(OUTPUT_CSV_FROM_FIRST, 'w', encoding='utf-8') as f:
            f.write("Package,Period,Period_Start,Downloads\n")
    
    if not os.path.exists(FIRST_DATE_CSV):
        with open(FIRST_DATE_CSV, 'w', encoding='utf-8') as f:
            f.write("Package,First_Download_Date,First_Downloads\n")

    total = len(target_packages)
    print(f"🚀 Fetching monthly downloads for {total} packages...")
    print(f"💾 Auto-save every {BATCH_SIZE} packages")
    print()

    successful_count = 0
    for i in range(0, total, BATCH_SIZE):
        batch = target_packages[i : i + BATCH_SIZE]
        batch_num = (i // BATCH_SIZE) + 1
        total_batches = (total + BATCH_SIZE - 1) // BATCH_SIZE
        
        print(f"[Batch {batch_num}/{total_batches}] ({i+1}-{min(i+BATCH_SIZE, total)}/{total}) Fetching: {batch[0]} ... {batch[-1] if len(batch)>1 else ''}")
        
        df_calendar, df_from_first, df_first_dates = get_monthly_data_batch(batch, START_DATE_DEFAULT)
        
        saved_count = 0
        if df_calendar is not None and not df_calendar.empty:
            df_calendar.to_csv(OUTPUT_CSV, mode='a', header=False, index=False, encoding='utf-8')
            saved_count = len(df_calendar['Package'].unique())
        
        if df_from_first is not None and not df_from_first.empty:
            df_from_first.to_csv(OUTPUT_CSV_FROM_FIRST, mode='a', header=False, index=False, encoding='utf-8')
        
        if df_first_dates is not None and not df_first_dates.empty:
            df_first_dates.to_csv(FIRST_DATE_CSV, mode='a', header=False, index=False, encoding='utf-8')
        
        successful_count += saved_count
        print(f"   💾 Saved {saved_count} packages. Total: {successful_count}/{i+len(batch)}")
        
        time.sleep(SLEEP_TIME)

    print(f"\n✅ Done!")
    print(f"   📊 Calendar monthly data: {OUTPUT_CSV}")
    print(f"   🔢 From-first 30-day data: {OUTPUT_CSV_FROM_FIRST}")
    print(f"   📅 First download dates: {FIRST_DATE_CSV}")

if __name__ == "__main__":
    main()
