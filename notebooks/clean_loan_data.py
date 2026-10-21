"""
CredX — Loan Risk & Repayment Analytics
Phase 3: Data Cleaning, Column Pruning, and Feature Standardization Pipeline

Author: Senior Data Analyst / Project Architect
File Location: notebooks/clean_loan_data.py
Input: data/raw/loan.csv
Outputs:
  - data/processed/loan_cleaned.csv
  - data/processed/cleaning_report.json
  - data/processed/dropped_columns.json
"""

import os
import json
import numpy as np
import pandas as pd
from datetime import datetime

# Define file paths
BASE_DIR = r"C:\Users\DELL\CredX"
RAW_FILE = os.path.join(BASE_DIR, "data", "raw", "loan.csv")
PROCESSED_DIR = os.path.join(BASE_DIR, "data", "processed")
OUTPUT_CLEANED_CSV = os.path.join(PROCESSED_DIR, "loan_cleaned.csv")
OUTPUT_REPORT_JSON = os.path.join(PROCESSED_DIR, "cleaning_report.json")
OUTPUT_DROPPED_JSON = os.path.join(PROCESSED_DIR, "dropped_columns.json")


def validate_source(raw_path: str) -> pd.DataFrame:
    """Load raw dataset and validate initial dimensions and integrity."""
    if not os.path.exists(raw_path):
        raise FileNotFoundError(f"Raw data file not found at: {raw_path}")
    
    print(f"[1/7] Loading raw data from: {raw_path} ...")
    df = pd.read_csv(raw_path, low_memory=False)
    rows, cols = df.shape
    print(f"      Initial shape: {rows:,} rows, {cols} columns")
    
    # Check expected core columns
    expected_core = [
        'id', 'member_id', 'loan_amnt', 'funded_amnt', 'term', 'int_rate',
        'installment', 'grade', 'sub_grade', 'annual_inc', 'issue_d',
        'loan_status', 'total_pymnt', 'total_rec_prncp', 'total_rec_int',
        'recoveries', 'out_prncp'
    ]
    missing_core = [col for col in expected_core if col not in df.columns]
    if missing_core:
        raise ValueError(f"Missing expected core columns: {missing_core}")
    
    return df


def prune_all_null_columns(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Identify and drop all-NULL columns programmatically."""
    print("[2/7] Identifying and pruning all-NULL columns ...")
    null_counts = df.isnull().sum()
    total_rows = len(df)
    
    all_null_cols = null_counts[null_counts == total_rows].index.tolist()
    
    dropped_metadata = {
        "total_columns_before": df.shape[1],
        "dropped_column_count": len(all_null_cols),
        "retained_column_count": df.shape[1] - len(all_null_cols),
        "dropped_columns": [
            {
                "column_name": col,
                "reason": "100% missing values (0 non-null records in 2007-2011 cohort)",
                "missing_count": int(null_counts[col]),
                "missing_percentage": 100.0
            }
            for col in all_null_cols
        ]
    }
    
    df_pruned = df.drop(columns=all_null_cols)
    print(f"      Dropped {len(all_null_cols)} columns with 100% nulls.")
    print(f"      Retained {df_pruned.shape[1]} columns.")
    return df_pruned, dropped_metadata


def clean_strings_and_terms(df: pd.DataFrame) -> pd.DataFrame:
    """Trim strings and standardize categorical and term fields."""
    print("[3/7] Cleaning strings, trimming whitespace, and standardizing term ...")
    df_cleaned = df.copy()
    
    # Standardize column names to lowercase snake_case
    df_cleaned.columns = [c.strip().lower().replace(' ', '_') for c in df_cleaned.columns]
    
    # Strip whitespace across all object/string columns
    string_cols = df_cleaned.select_dtypes(include=['object']).columns
    for col in string_cols:
        df_cleaned[col] = df_cleaned[col].apply(lambda x: x.strip() if isinstance(x, str) else x)
    
    # Validate term values
    term_counts = df_cleaned['term'].value_counts(dropna=False).to_dict()
    print(f"      Standardized 'term' values: {term_counts}")
    
    return df_cleaned


def standardize_numeric_fields(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Convert int_rate and revol_util from percentage strings to numeric percentage points."""
    print("[4/7] Converting percentages (int_rate, revol_util) and numeric types ...")
    df_cleaned = df.copy()
    conversion_stats = {}
    
    # 1. int_rate conversion
    try:
        raw_int = df_cleaned['int_rate'].astype(str).str.rstrip('%').str.strip()
        df_cleaned['int_rate'] = pd.to_numeric(raw_int, errors='coerce')
        int_fails = df_cleaned['int_rate'].isnull().sum()
        conversion_stats['int_rate'] = {
            "status": "Success",
            "unit": "Percentage Points (e.g. 10.65 = 10.65%)",
            "conversion_failures": int(int_fails),
            "min_value": float(df_cleaned['int_rate'].min()),
            "max_value": float(df_cleaned['int_rate'].max())
        }
    except Exception as e:
        conversion_stats['int_rate'] = {"status": f"Error: {str(e)}"}
    
    # 2. revol_util conversion (preserving legitimate nulls)
    try:
        raw_revol = df_cleaned['revol_util'].astype(str).str.rstrip('%').str.strip()
        # mask 'nan' strings
        raw_revol = raw_revol.replace({'nan': np.nan, 'None': np.nan, '': np.nan})
        df_cleaned['revol_util'] = pd.to_numeric(raw_revol, errors='coerce')
        revol_nulls = df_cleaned['revol_util'].isnull().sum()
        conversion_stats['revol_util'] = {
            "status": "Success",
            "unit": "Percentage Points (e.g. 83.70 = 83.70%)",
            "null_count_preserved": int(revol_nulls),
            "min_value": float(df_cleaned['revol_util'].dropna().min()),
            "max_value": float(df_cleaned['revol_util'].dropna().max())
        }
    except Exception as e:
        conversion_stats['revol_util'] = {"status": f"Error: {str(e)}"}
    
    return df_cleaned, conversion_stats


def parse_month_year(val, is_earliest_cr=False):
    """
    Parse 'Mon-YY' strings to 'YYYY-MM-01' with correct century handling.
    For earliest_cr_line: 2-digit years <= 11 are 2000s (2000-2011),
                         years > 11 are 1900s (1946-1999).
    For loan lifecycle dates: all are in 2000s (2007-2016).
    """
    if pd.isnull(val):
        return None
    val_str = str(val).strip()
    if not val_str or val_str.lower() in ['nan', 'none', 'null']:
        return None
    try:
        parts = val_str.split('-')
        if len(parts) != 2:
            return None
        mon_str, yr_str = parts[0], parts[1]
        yr = int(yr_str)
        if is_earliest_cr:
            full_yr = 2000 + yr if yr <= 11 else 1900 + yr
        else:
            full_yr = 2000 + yr if yr < 50 else 1900 + yr
        dt = pd.to_datetime(f"{mon_str}-01-{full_yr}", format="%b-%d-%Y")
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return None


def standardize_date_fields(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Standardize date columns to MySQL-compatible YYYY-MM-DD strings."""
    print("[5/7] Parsing and standardizing date columns to YYYY-MM-DD ...")
    df_cleaned = df.copy()
    date_cols = ['issue_d', 'last_pymnt_d', 'next_pymnt_d', 'last_credit_pull_d', 'earliest_cr_line']
    date_audit = {}
    
    for col in date_cols:
        if col in df_cleaned.columns:
            is_ecr = (col == 'earliest_cr_line')
            original_nulls = int(df_cleaned[col].isnull().sum())
            df_cleaned[col] = df_cleaned[col].apply(lambda x: parse_month_year(x, is_earliest_cr=is_ecr))
            new_nulls = int(df_cleaned[col].isnull().sum())
            parsing_failures = new_nulls - original_nulls
            
            non_null_series = df_cleaned[col].dropna()
            min_date = non_null_series.min() if not non_null_series.empty else "N/A"
            max_date = non_null_series.max() if not non_null_series.empty else "N/A"
            
            date_audit[col] = {
                "original_nulls": original_nulls,
                "cleaned_nulls": new_nulls,
                "parsing_failures": parsing_failures,
                "min_date": min_date,
                "max_date": max_date,
                "century_handling": "Split 1900s/2000s at year 2011" if is_ecr else "2000s vintage"
            }
            print(f"      {col:20} -> min: {min_date}, max: {max_date}, failures: {parsing_failures}")
    
    return df_cleaned, date_audit


def add_derived_analytical_features(df: pd.DataFrame) -> pd.DataFrame:
    """Generate well-defined, defensible financial and portfolio features."""
    print("[6/7] Adding derived analytical features ...")
    df_feat = df.copy()
    
    # 1. Parse loan term in months as integer
    df_feat['loan_term_months'] = df_feat['term'].str.extract(r'(\d+)').astype(int)
    
    # 2. Loan to Annual Income Ratio (safe against zero/null income)
    df_feat['loan_to_income_ratio'] = np.where(
        (df_feat['annual_inc'].notnull()) & (df_feat['annual_inc'] > 0),
        (df_feat['loan_amnt'] / df_feat['annual_inc']).round(4),
        np.nan
    )
    
    # 3. Principal Recovery Ratio = total_rec_prncp / funded_amnt (safe against zero funding)
    df_feat['principal_recovery_ratio'] = np.where(
        (df_feat['funded_amnt'].notnull()) & (df_feat['funded_amnt'] > 0),
        (df_feat['total_rec_prncp'] / df_feat['funded_amnt']).round(4),
        np.nan
    )
    
    # 4. Interest to Funded Ratio = total_rec_int / funded_amnt (Interest return on capital)
    df_feat['interest_to_funded_ratio'] = np.where(
        (df_feat['funded_amnt'].notnull()) & (df_feat['funded_amnt'] > 0),
        (df_feat['total_rec_int'] / df_feat['funded_amnt']).round(4),
        np.nan
    )
    
    # 5. Net Recovery Amount = recoveries - collection_recovery_fee
    df_feat['net_recoveries'] = (df_feat['recoveries'] - df_feat['collection_recovery_fee']).round(2)
    
    # 6. Terminal Outcome Status Flag (1 for Fully Paid and Charged Off; 0 for Current)
    df_feat['is_terminal_status'] = np.where(
        df_feat['loan_status'].isin(['Fully Paid', 'Charged Off']), 1, 0
    )
    
    # 7. Charge-Off Outcome Flag (1 for Charged Off, 0 for Fully Paid, NaN for active Current)
    df_feat['is_charged_off'] = np.where(
        df_feat['loan_status'] == 'Charged Off', 1,
        np.where(df_feat['loan_status'] == 'Fully Paid', 0, np.nan)
    )
    
    # 8. Temporal dimensions derived from issue_d
    issue_dt = pd.to_datetime(df_feat['issue_d'], format='%Y-%m-%d', errors='coerce')
    df_feat['issue_year'] = issue_dt.dt.year.astype('Int64')
    df_feat['issue_year_month'] = issue_dt.dt.strftime('%Y-%m')
    
    print(f"      Added 8 derived features: loan_term_months, loan_to_income_ratio, principal_recovery_ratio,")
    print(f"      interest_to_funded_ratio, net_recoveries, is_terminal_status, is_charged_off, issue_year, issue_year_month.")
    
    return df_feat


def run_data_quality_reconciliation(df: pd.DataFrame) -> dict:
    """Validate data quality, negative balances, and financial reconciliation."""
    print("[7/7] Validating data quality and financial reconciliation ...")
    audit_results = {}
    
    # 1. Duplicate check
    audit_results['total_rows'] = len(df)
    audit_results['total_columns'] = df.shape[1]
    audit_results['duplicate_rows'] = int(df.duplicated().sum())
    audit_results['duplicate_ids'] = int(df['id'].duplicated().sum())
    
    # 2. Loan status frequencies
    audit_results['loan_status_distribution'] = df['loan_status'].value_counts().to_dict()
    
    # 3. Negative monetary values check
    monetary_cols = [
        'loan_amnt', 'funded_amnt', 'funded_amnt_inv', 'installment',
        'annual_inc', 'revol_bal', 'out_prncp', 'total_pymnt',
        'total_rec_prncp', 'total_rec_int', 'total_rec_late_fee', 'recoveries'
    ]
    negative_counts = {}
    for col in monetary_cols:
        if col in df.columns:
            negative_counts[col] = int((df[col] < 0).sum())
    audit_results['negative_monetary_counts'] = negative_counts
    
    # 4. Total Payment Component Reconciliation:
    # total_pymnt = total_rec_prncp + total_rec_int + total_rec_late_fee + recoveries
    expected_pymnt = (
        df['total_rec_prncp'] +
        df['total_rec_int'] +
        df['total_rec_late_fee'] +
        df['recoveries']
    )
    pymnt_diff = (df['total_pymnt'] - expected_pymnt).abs()
    audit_results['payment_reconciliation'] = {
        "formula": "total_pymnt == total_rec_prncp + total_rec_int + total_rec_late_fee + recoveries",
        "max_absolute_discrepancy": float(pymnt_diff.max()),
        "rows_with_discrepancy_over_1_cent": int((pymnt_diff > 0.01).sum()),
        "reconciliation_verdict": "Fully Reconciled (within 1 cent rounding)" if (pymnt_diff > 0.01).sum() == 0 else "Discrepancies Found"
    }
    
    # 5. Principal vs Funded check
    excess_prncp = (df['total_rec_prncp'] > df['funded_amnt'] + 1).sum()
    audit_results['principal_exceeds_funded_count'] = int(excess_prncp)
    
    return audit_results


def main():
    # 1. Validate Source
    df_raw = validate_source(RAW_FILE)
    
    # 2. Prune all-NULL columns
    df_pruned, dropped_metadata = prune_all_null_columns(df_raw)
    
    # 3. Clean strings & term
    df_strings = clean_strings_and_terms(df_pruned)
    
    # 4. Standardize numeric / percentage fields
    df_numeric, numeric_stats = standardize_numeric_fields(df_strings)
    
    # 5. Standardize dates
    df_dates, date_audit = standardize_date_fields(df_numeric)
    
    # 6. Add derived features
    df_final = add_derived_analytical_features(df_dates)
    
    # 7. Validate Data Quality & Reconciliation
    dq_results = run_data_quality_reconciliation(df_final)
    
    # Build complete cleaning report
    full_report = {
        "project_name": "CredX — Loan Risk & Repayment Analytics",
        "phase": "Phase 3: Python Data Cleaning, Column Pruning, and Feature Standardization",
        "execution_timestamp": datetime.now().isoformat(),
        "input_file": RAW_FILE,
        "input_dimensions": {
            "rows": int(df_raw.shape[0]),
            "columns": int(df_raw.shape[1])
        },
        "output_dimensions": {
            "rows": int(df_final.shape[0]),
            "columns": int(df_final.shape[1])
        },
        "dropped_columns_summary": {
            "dropped_count": dropped_metadata["dropped_column_count"],
            "retained_count": dropped_metadata["retained_column_count"]
        },
        "numeric_conversions": numeric_stats,
        "date_standardization": date_audit,
        "data_quality_validation": dq_results
    }
    
    # Ensure processed directory exists
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    
    # Save Outputs
    print(f"\nSaving processed files:")
    print(f"  -> {OUTPUT_CLEANED_CSV}")
    df_final.to_csv(OUTPUT_CLEANED_CSV, index=False)
    
    print(f"  -> {OUTPUT_REPORT_JSON}")
    with open(OUTPUT_REPORT_JSON, 'w', encoding='utf-8') as f:
        json.dump(full_report, f, indent=2)
        
    print(f"  -> {OUTPUT_DROPPED_JSON}")
    with open(OUTPUT_DROPPED_JSON, 'w', encoding='utf-8') as f:
        json.dump(dropped_metadata, f, indent=2)
        
    print("\n[SUCCESS] Phase 3 Data Cleaning completed successfully!")
    print(f"Final Cleaned Dataset: {df_final.shape[0]:,} rows, {df_final.shape[1]} columns.")


if __name__ == "__main__":
    main()
