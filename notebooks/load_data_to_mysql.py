"""
CredX — Loan Risk & Repayment Analytics
Phase 4: Automated MySQL Star Schema Ingestion & Validation Pipeline
File: notebooks/load_data_to_mysql.py

This script safely loads the verified cleaned dataset (`data/processed/loan_cleaned.csv`)
into a MySQL 8.0+ Star Schema database (`credx`) adhering to Kimball dimensional modeling.

Key Features:
- Strict pre-flight validation of input schema and 39,717 row count.
- Deterministic dimension-before-fact ingestion hierarchy.
- Parameterized batch loading (default batch size: 5,000) for low memory usage.
- Strict ACID transaction management: commits only when load and all validations pass;
  rolls back completely on any error.
- Idempotent insertion strategy via ON DUPLICATE KEY UPDATE to prevent duplicate rows.
- Comprehensive 11-point post-load validation suite verifying referential integrity,
  row counts, financial reconciliations, and NULL semantics.
- Standalone --dry-run mode to verify data mapping without connecting to MySQL.
"""

import os
import sys
import argparse
import logging
from datetime import datetime
import pandas as pd
import numpy as np

# Load environment variables if python-dotenv is available
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("CredX_Loader")

# Constants
EXPECTED_ROW_COUNT = 39717
DEFAULT_CSV_PATH = os.path.join("data", "processed", "loan_cleaned.csv")
SCHEMA_SQL_PATH = os.path.join("sql", "01_create_schema.sql")

REQUIRED_COLUMNS = [
    'id', 'member_id', 'loan_amnt', 'funded_amnt', 'funded_amnt_inv', 'term',
    'int_rate', 'installment', 'grade', 'sub_grade', 'emp_title', 'emp_length',
    'home_ownership', 'annual_inc', 'verification_status', 'issue_d',
    'loan_status', 'pymnt_plan', 'url', 'desc', 'purpose', 'title', 'zip_code',
    'addr_state', 'dti', 'delinq_2yrs', 'earliest_cr_line', 'inq_last_6mths',
    'mths_since_last_delinq', 'mths_since_last_record', 'open_acc', 'pub_rec',
    'revol_bal', 'revol_util', 'total_acc', 'initial_list_status', 'out_prncp',
    'out_prncp_inv', 'total_pymnt', 'total_pymnt_inv', 'total_rec_prncp',
    'total_rec_int', 'total_rec_late_fee', 'recoveries', 'collection_recovery_fee',
    'last_pymnt_d', 'last_pymnt_amnt', 'next_pymnt_d', 'last_credit_pull_d',
    'collections_12_mths_ex_med', 'policy_code', 'application_type',
    'acc_now_delinq', 'chargeoff_within_12_mths', 'delinq_amnt',
    'pub_rec_bankruptcies', 'tax_liens', 'loan_term_months',
    'loan_to_income_ratio', 'principal_recovery_ratio',
    'interest_to_funded_ratio', 'net_recoveries', 'is_terminal_status',
    'is_charged_off', 'issue_year', 'issue_year_month'
]


def sanitize(val):
    """Convert pandas/numpy NaN or missing values to Python None for clean SQL NULL insertion."""
    if pd.isna(val):
        return None
    return val


def sanitize_int(val):
    """Convert nullable numeric values to integer or None."""
    if pd.isna(val):
        return None
    return int(val)


def get_db_config():
    """Retrieve database connection parameters safely from environment."""
    return {
        "host": os.getenv("MYSQL_HOST", "localhost"),
        "port": int(os.getenv("MYSQL_PORT", 3306)),
        "user": os.getenv("MYSQL_USER", "root"),
        "password": os.getenv("MYSQL_PASSWORD", ""),
        "database": os.getenv("MYSQL_DATABASE", "credx")
    }


def get_mysql_connection():
    """Establish connection to MySQL using mysql-connector-python with automatic database creation if permitted."""
    try:
        import mysql.connector
        from mysql.connector import errorcode
    except ImportError:
        logger.error("mysql-connector-python is not installed. Run: pip install mysql-connector-python")
        sys.exit(1)

    config = get_db_config()
    masked_config = {k: ("***" if k == "password" else v) for k, v in config.items()}
    logger.info(f"Attempting to connect to MySQL with parameters: {masked_config}")

    target_db = config["database"]

    try:
        # First attempt connecting directly to the target database
        conn = mysql.connector.connect(
            host=config["host"],
            port=config["port"],
            user=config["user"],
            password=config["password"],
            database=target_db,
            autocommit=False
        )
        logger.info(f"Successfully connected directly to existing database '{target_db}'.")
        return conn
    except mysql.connector.Error as err:
        if err.errno == errorcode.ER_BAD_DB_ERROR:
            logger.info(f"Database '{target_db}' does not exist. Attempting to connect to server and create it...")
            try:
                server_conn = mysql.connector.connect(
                    host=config["host"],
                    port=config["port"],
                    user=config["user"],
                    password=config["password"],
                    autocommit=True
                )
                cur = server_conn.cursor()
                cur.execute(f"CREATE DATABASE IF NOT EXISTS `{target_db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
                cur.close()
                server_conn.close()
                logger.info(f"Database '{target_db}' created successfully. Reconnecting...")
                
                conn = mysql.connector.connect(
                    host=config["host"],
                    port=config["port"],
                    user=config["user"],
                    password=config["password"],
                    database=target_db,
                    autocommit=False
                )
                return conn
            except mysql.connector.Error as create_err:
                logger.error(f"Failed to create database '{target_db}': {create_err}")
                return None
        else:
            logger.error(f"Failed to connect to MySQL: {err}")
            return None


def validate_source_csv(csv_path):
    """Strictly validate input CSV existence, row count, and schema columns."""
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Source file not found at: {csv_path}")

    logger.info(f"Reading and validating source dataset from: {csv_path}...")
    df = pd.read_csv(csv_path, low_memory=False)

    if len(df) != EXPECTED_ROW_COUNT:
        raise ValueError(
            f"Pre-flight validation failed: Expected {EXPECTED_ROW_COUNT} rows, found {len(df)}"
        )

    missing_cols = set(REQUIRED_COLUMNS) - set(df.columns)
    if missing_cols:
        raise ValueError(f"Pre-flight validation failed: Missing required columns: {missing_cols}")

    logger.info(f"Source dataset validated: {len(df):,} rows and {len(df.columns)} columns present.")
    return df


def execute_ddl_script(conn, sql_path):
    """Execute DDL statements from sql/01_create_schema.sql."""
    if not os.path.exists(sql_path):
        raise FileNotFoundError(f"DDL script not found at: {sql_path}")

    logger.info(f"Executing DDL script from {sql_path}...")
    with open(sql_path, "r", encoding="utf-8") as f:
        sql_content = f.read()

    # Split statements by semicolon while ignoring comments
    statements = [stmt.strip() for stmt in sql_content.split(";") if stmt.strip()]
    cursor = conn.cursor()
    for stmt in statements:
        # Skip pure comment blocks or empty commands
        clean_stmt = "\n".join([line for line in stmt.splitlines() if not line.strip().startswith("--")]).strip()
        if clean_stmt:
            cursor.execute(clean_stmt)
    conn.commit()
    cursor.close()
    logger.info("DDL script executed successfully.")


def generate_dim_dates():
    """Generate conformed daily date dimension DataFrame spanning 1946-01-01 to 2016-12-31."""
    date_range = pd.date_range(start="1946-01-01", end="2016-12-31", freq="D")
    return pd.DataFrame({
        "calendar_date": date_range.strftime("%Y-%m-%d"),
        "date_key": date_range.strftime("%Y%m%d").astype(int),
        "year": date_range.year,
        "quarter": date_range.quarter,
        "month": date_range.month,
        "month_name": date_range.strftime("%B"),
        "month_short_name": date_range.strftime("%b"),
        "year_month": date_range.strftime("%Y-%m"),
        "day": date_range.day,
        "day_name": date_range.strftime("%A"),
        "is_weekend": date_range.dayofweek.isin([5, 6]).astype(int)
    })


def load_dim_dates(conn, dates_df, batch_size=5000):
    """Load dim_dates table idempotently."""
    logger.info(f"Loading dim_dates ({len(dates_df):,} rows)...")
    sql = """
    INSERT INTO dim_dates (
        `calendar_date`, `date_key`, `year`, `quarter`, `month`, `month_name`,
        `month_short_name`, `year_month`, `day`, `day_name`, `is_weekend`
    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON DUPLICATE KEY UPDATE `calendar_date` = `calendar_date`;
    """
    records = [
        (
            row["calendar_date"], int(row["date_key"]), int(row["year"]),
            int(row["quarter"]), int(row["month"]), str(row["month_name"]),
            str(row["month_short_name"]), str(row["year_month"]),
            int(row["day"]), str(row["day_name"]), int(row["is_weekend"])
        )
        for _, row in dates_df.iterrows()
    ]

    cursor = conn.cursor()
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        cursor.executemany(sql, batch)
    cursor.close()
    logger.info("dim_dates successfully loaded.")


def load_dim_borrowers(conn, df, batch_size=5000):
    """Load dim_borrowers table idempotently."""
    logger.info(f"Loading dim_borrowers ({len(df):,} rows)...")
    sql = """
    INSERT INTO dim_borrowers (
        member_id, emp_title, emp_length, home_ownership, annual_inc,
        verification_status, zip_code, addr_state, dti, earliest_cr_line,
        open_acc, total_acc, revol_bal, revol_util, pub_rec,
        pub_rec_bankruptcies, delinq_2yrs, inq_last_6mths,
        mths_since_last_delinq, mths_since_last_record,
        collections_12_mths_ex_med, chargeoff_within_12_mths,
        delinq_amnt, tax_liens, acc_now_delinq
    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON DUPLICATE KEY UPDATE
        emp_title = VALUES(emp_title),
        emp_length = VALUES(emp_length),
        home_ownership = VALUES(home_ownership),
        annual_inc = VALUES(annual_inc),
        verification_status = VALUES(verification_status),
        zip_code = VALUES(zip_code),
        addr_state = VALUES(addr_state),
        dti = VALUES(dti),
        earliest_cr_line = VALUES(earliest_cr_line),
        open_acc = VALUES(open_acc),
        total_acc = VALUES(total_acc),
        revol_bal = VALUES(revol_bal),
        revol_util = VALUES(revol_util),
        pub_rec = VALUES(pub_rec),
        pub_rec_bankruptcies = VALUES(pub_rec_bankruptcies),
        delinq_2yrs = VALUES(delinq_2yrs),
        inq_last_6mths = VALUES(inq_last_6mths),
        mths_since_last_delinq = VALUES(mths_since_last_delinq),
        mths_since_last_record = VALUES(mths_since_last_record),
        collections_12_mths_ex_med = VALUES(collections_12_mths_ex_med),
        chargeoff_within_12_mths = VALUES(chargeoff_within_12_mths),
        delinq_amnt = VALUES(delinq_amnt),
        tax_liens = VALUES(tax_liens),
        acc_now_delinq = VALUES(acc_now_delinq);
    """
    records = []
    for _, row in df.iterrows():
        records.append((
            int(row['member_id']),
            sanitize(row['emp_title']),
            sanitize(row['emp_length']),
            str(row['home_ownership']),
            float(row['annual_inc']),
            str(row['verification_status']),
            str(row['zip_code']),
            str(row['addr_state']),
            float(row['dti']),
            sanitize(row['earliest_cr_line']),
            int(row['open_acc']),
            int(row['total_acc']),
            float(row['revol_bal']),
            sanitize(row['revol_util']),
            int(row['pub_rec']),
            sanitize_int(row['pub_rec_bankruptcies']),
            int(row['delinq_2yrs']),
            int(row['inq_last_6mths']),
            sanitize_int(row['mths_since_last_delinq']),
            sanitize_int(row['mths_since_last_record']),
            sanitize_int(row['collections_12_mths_ex_med']),
            sanitize_int(row['chargeoff_within_12_mths']),
            float(row['delinq_amnt']),
            sanitize_int(row['tax_liens']),
            int(row['acc_now_delinq'])
        ))

    cursor = conn.cursor()
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        cursor.executemany(sql, batch)
    cursor.close()
    logger.info("dim_borrowers successfully loaded.")


def load_dim_loan_details(conn, df, batch_size=5000):
    """Load dim_loan_details table idempotently."""
    logger.info(f"Loading dim_loan_details ({len(df):,} rows)...")
    sql = """
    INSERT INTO dim_loan_details (
        loan_id, term, loan_term_months, grade, sub_grade, int_rate,
        installment, purpose, title, description, initial_list_status,
        application_type, pymnt_plan, policy_code, url
    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON DUPLICATE KEY UPDATE
        term = VALUES(term),
        loan_term_months = VALUES(loan_term_months),
        grade = VALUES(grade),
        sub_grade = VALUES(sub_grade),
        int_rate = VALUES(int_rate),
        installment = VALUES(installment),
        purpose = VALUES(purpose),
        title = VALUES(title),
        description = VALUES(description),
        initial_list_status = VALUES(initial_list_status),
        application_type = VALUES(application_type),
        pymnt_plan = VALUES(pymnt_plan),
        policy_code = VALUES(policy_code),
        url = VALUES(url);
    """
    records = []
    for _, row in df.iterrows():
        records.append((
            int(row['id']),
            str(row['term']),
            int(row['loan_term_months']),
            str(row['grade']),
            str(row['sub_grade']),
            float(row['int_rate']),
            float(row['installment']),
            str(row['purpose']),
            sanitize(row['title']),
            sanitize(row['desc']),
            str(row['initial_list_status']),
            str(row['application_type']),
            str(row['pymnt_plan']),
            int(row['policy_code']),
            sanitize(row['url'])
        ))

    cursor = conn.cursor()
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        cursor.executemany(sql, batch)
    cursor.close()
    logger.info("dim_loan_details successfully loaded.")


def load_fact_loans(conn, df, batch_size=5000):
    """Load fact_loans table with surrogate foreign keys resolved from dimensions."""
    logger.info("Resolving dimension surrogate keys for fact_loans...")
    cursor = conn.cursor()

    cursor.execute("SELECT member_id, borrower_key FROM dim_borrowers;")
    borrower_map = dict(cursor.fetchall())

    cursor.execute("SELECT loan_id, loan_detail_key FROM dim_loan_details;")
    detail_map = dict(cursor.fetchall())
    cursor.close()

    logger.info(f"Loading fact_loans ({len(df):,} rows)...")
    sql = """
    INSERT INTO fact_loans (
        loan_id, borrower_key, loan_detail_key, issue_date, last_pymnt_date,
        next_pymnt_date, last_credit_pull_date, loan_status, is_terminal_status,
        is_charged_off, loan_amnt, funded_amnt, funded_amnt_inv, total_pymnt,
        total_pymnt_inv, total_rec_prncp, total_rec_int, total_rec_late_fee,
        last_pymnt_amnt, out_prncp, out_prncp_inv, recoveries,
        collection_recovery_fee, net_recoveries, loan_to_income_ratio,
        principal_recovery_ratio, interest_to_funded_ratio
    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON DUPLICATE KEY UPDATE
        borrower_key = VALUES(borrower_key),
        loan_detail_key = VALUES(loan_detail_key),
        issue_date = VALUES(issue_date),
        last_pymnt_date = VALUES(last_pymnt_date),
        next_pymnt_date = VALUES(next_pymnt_date),
        last_credit_pull_date = VALUES(last_credit_pull_date),
        loan_status = VALUES(loan_status),
        is_terminal_status = VALUES(is_terminal_status),
        is_charged_off = VALUES(is_charged_off),
        loan_amnt = VALUES(loan_amnt),
        funded_amnt = VALUES(funded_amnt),
        funded_amnt_inv = VALUES(funded_amnt_inv),
        total_pymnt = VALUES(total_pymnt),
        total_pymnt_inv = VALUES(total_pymnt_inv),
        total_rec_prncp = VALUES(total_rec_prncp),
        total_rec_int = VALUES(total_rec_int),
        total_rec_late_fee = VALUES(total_rec_late_fee),
        last_pymnt_amnt = VALUES(last_pymnt_amnt),
        out_prncp = VALUES(out_prncp),
        out_prncp_inv = VALUES(out_prncp_inv),
        recoveries = VALUES(recoveries),
        collection_recovery_fee = VALUES(collection_recovery_fee),
        net_recoveries = VALUES(net_recoveries),
        loan_to_income_ratio = VALUES(loan_to_income_ratio),
        principal_recovery_ratio = VALUES(principal_recovery_ratio),
        interest_to_funded_ratio = VALUES(interest_to_funded_ratio);
    """
    records = []
    for _, row in df.iterrows():
        lid = int(row['id'])
        mid = int(row['member_id'])
        b_key = borrower_map[mid]
        d_key = detail_map[lid]

        records.append((
            lid,
            b_key,
            d_key,
            row['issue_d'],
            sanitize(row['last_pymnt_d']),
            sanitize(row['next_pymnt_d']),
            sanitize(row['last_credit_pull_d']),
            str(row['loan_status']),
            int(row['is_terminal_status']),
            sanitize_int(row['is_charged_off']),
            float(row['loan_amnt']),
            float(row['funded_amnt']),
            float(row['funded_amnt_inv']),
            float(row['total_pymnt']),
            float(row['total_pymnt_inv']),
            float(row['total_rec_prncp']),
            float(row['total_rec_int']),
            float(row['total_rec_late_fee']),
            float(row['last_pymnt_amnt']),
            float(row['out_prncp']),
            float(row['out_prncp_inv']),
            float(row['recoveries']),
            float(row['collection_recovery_fee']),
            float(row['net_recoveries']),
            float(row['loan_to_income_ratio']),
            float(row['principal_recovery_ratio']),
            float(row['interest_to_funded_ratio'])
        ))

    cursor = conn.cursor()
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        cursor.executemany(sql, batch)
    cursor.close()
    logger.info("fact_loans successfully loaded.")


def validate_database_load(conn, df_source):
    """
    Run the 11-point validation suite against the database.
    Returns (True, dict) if all checks pass, (False, dict) otherwise.
    """
    logger.info("=" * 60)
    logger.info("RUNNING PHASE 4 DATABASE VALIDATION SUITE (11 CHECKS)")
    logger.info("=" * 60)
    cursor = conn.cursor()
    results = {}
    all_passed = True

    # Check 1: Total fact rows equal 39,717
    cursor.execute("SELECT COUNT(*) FROM fact_loans;")
    fact_count = cursor.fetchone()[0]
    p1 = (fact_count == EXPECTED_ROW_COUNT)
    results['check_1_fact_row_count'] = {'passed': p1, 'observed': fact_count, 'expected': EXPECTED_ROW_COUNT}
    logger.info(f"Check 1 - Total Fact Rows: {fact_count:,} (Expected: {EXPECTED_ROW_COUNT:,}) -> {'PASS' if p1 else 'FAIL'}")
    if not p1: all_passed = False

    # Check 2: Original loan identifiers are unique
    cursor.execute("SELECT COUNT(DISTINCT loan_id) FROM fact_loans;")
    distinct_loans = cursor.fetchone()[0]
    p2 = (distinct_loans == EXPECTED_ROW_COUNT)
    results['check_2_unique_loan_ids'] = {'passed': p2, 'observed': distinct_loans, 'expected': EXPECTED_ROW_COUNT}
    logger.info(f"Check 2 - Unique Loan IDs: {distinct_loans:,} -> {'PASS' if p2 else 'FAIL'}")
    if not p2: all_passed = False

    # Check 3: Dimension foreign keys have no orphan records
    cursor.execute("SELECT COUNT(*) FROM fact_loans f LEFT JOIN dim_borrowers b ON f.borrower_key = b.borrower_key WHERE b.borrower_key IS NULL;")
    orphan_b = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM fact_loans f LEFT JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key WHERE d.loan_detail_key IS NULL;")
    orphan_d = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM fact_loans f LEFT JOIN dim_dates dt ON f.issue_date = dt.calendar_date WHERE dt.calendar_date IS NULL;")
    orphan_date = cursor.fetchone()[0]
    p3 = (orphan_b == 0 and orphan_d == 0 and orphan_date == 0)
    results['check_3_orphan_records'] = {'passed': p3, 'borrowers': orphan_b, 'details': orphan_d, 'dates': orphan_date}
    logger.info(f"Check 3 - Orphan Foreign Keys: borrowers={orphan_b}, details={orphan_d}, dates={orphan_date} -> {'PASS' if p3 else 'FAIL'}")
    if not p3: all_passed = False

    # Check 4: Loan status counts match Phase 3
    cursor.execute("SELECT loan_status, COUNT(*) FROM fact_loans GROUP BY loan_status;")
    status_db = dict(cursor.fetchall())
    expected_status = {'Fully Paid': 32950, 'Charged Off': 5627, 'Current': 1140}
    p4 = (status_db == expected_status)
    results['check_4_status_counts'] = {'passed': p4, 'observed': status_db, 'expected': expected_status}
    logger.info(f"Check 4 - Loan Status Distribution: {status_db} -> {'PASS' if p4 else 'FAIL'}")
    if not p4: all_passed = False

    # Check 5: is_charged_off counts and NULL handling match Phase 3
    cursor.execute("SELECT COUNT(*) FROM fact_loans WHERE is_charged_off = 1;")
    co_1 = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM fact_loans WHERE is_charged_off = 0;")
    co_0 = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM fact_loans WHERE is_charged_off IS NULL;")
    co_null = cursor.fetchone()[0]
    p5 = (co_1 == 5627 and co_0 == 32950 and co_null == 1140)
    results['check_5_charged_off_nulls'] = {'passed': p5, 'charged_off': co_1, 'fully_paid': co_0, 'current_null': co_null}
    logger.info(f"Check 5 - is_charged_off Distribution: 1={co_1:,}, 0={co_0:,}, NULL={co_null:,} -> {'PASS' if p5 else 'FAIL'}")
    if not p5: all_passed = False

    # Check 6: Origination-year counts match cleaned dataset
    cursor.execute("""
        SELECT dt.year, COUNT(*)
        FROM fact_loans f
        JOIN dim_dates dt ON f.issue_date = dt.calendar_date
        GROUP BY dt.year
        ORDER BY dt.year;
    """)
    years_db = dict(cursor.fetchall())
    expected_years = dict(df_source['issue_year'].value_counts().sort_index())
    p6 = (years_db == expected_years)
    results['check_6_origination_years'] = {'passed': p6, 'observed': years_db, 'expected': expected_years}
    logger.info(f"Check 6 - Origination Year Counts: {years_db} -> {'PASS' if p6 else 'FAIL'}")
    if not p6: all_passed = False

    # Check 7: Financial totals reconcile within documented tolerance ($1.00 due to fractional-cent rounding in DECIMAL(10,2))
    fin_cols = ['loan_amnt', 'funded_amnt', 'total_pymnt', 'total_rec_prncp', 'total_rec_int', 'recoveries']
    fin_results = {}
    p7 = True
    RECONCILIATION_TOLERANCE = 1.00  # $1.00 tolerance across 39,717 rows
    for col in fin_cols:
        cursor.execute(f"SELECT SUM({col}) FROM fact_loans;")
        db_sum = float(cursor.fetchone()[0])
        csv_sum = float(df_source[col].sum())
        diff = abs(db_sum - csv_sum)
        passed = (diff <= RECONCILIATION_TOLERANCE)
        if not passed: p7 = False
        fin_results[col] = {'db_sum': round(db_sum, 2), 'csv_sum': round(csv_sum, 2), 'diff': round(diff, 4), 'passed': passed}
        logger.info(f"Check 7 - Sum({col}): DB=${db_sum:,.2f}, CSV=${csv_sum:,.2f}, Diff=${diff:.4f} (Tol: ${RECONCILIATION_TOLERANCE:.2f}) -> {'PASS' if passed else 'FAIL'}")
    results['check_7_financial_totals'] = {'passed': p7, 'details': fin_results}
    if not p7: all_passed = False

    # Check 8: Percentage fields retain percentage-point values
    cursor.execute("SELECT MIN(int_rate), MAX(int_rate), AVG(int_rate) FROM dim_loan_details;")
    int_stats = cursor.fetchone()
    cursor.execute("SELECT MIN(revol_util), MAX(revol_util), AVG(revol_util) FROM dim_borrowers WHERE revol_util IS NOT NULL;")
    util_stats = cursor.fetchone()
    p8 = (float(int_stats[0]) >= 5.0 and float(int_stats[1]) <= 30.0 and float(util_stats[1]) <= 100.0)
    results['check_8_percentage_points'] = {
        'passed': p8,
        'int_rate': {'min': float(int_stats[0]), 'max': float(int_stats[1]), 'avg': round(float(int_stats[2]), 2)},
        'revol_util': {'min': float(util_stats[0]), 'max': float(util_stats[1]), 'avg': round(float(util_stats[2]), 2)}
    }
    logger.info(f"Check 8 - Percentage Points: int_rate=[{int_stats[0]}, {int_stats[1]}], revol_util=[{util_stats[0]}, {util_stats[1]}] -> {'PASS' if p8 else 'FAIL'}")
    if not p8: all_passed = False

    # Check 9: NULL payment dates remain NULL
    cursor.execute("SELECT COUNT(*) FROM fact_loans WHERE last_pymnt_date IS NULL;")
    null_last = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM fact_loans WHERE next_pymnt_date IS NULL;")
    null_next = cursor.fetchone()[0]
    p9 = (null_last == 71 and null_next == 38577)
    results['check_9_null_dates'] = {'passed': p9, 'null_last_pymnt': null_last, 'null_next_pymnt': null_next}
    logger.info(f"Check 9 - NULL Payment Dates: last_pymnt_date NULLs={null_last:,} (Exp: 71), next_pymnt_date NULLs={null_next:,} (Exp: 38,577) -> {'PASS' if p9 else 'FAIL'}")
    if not p9: all_passed = False

    # Check 10: 71 records with missing last_pymnt_d are not assumed zero recovery
    cursor.execute("""
        SELECT 
            COUNT(*), 
            SUM(CASE WHEN total_pymnt > 0 THEN 1 ELSE 0 END),
            SUM(CASE WHEN recoveries > 0 THEN 1 ELSE 0 END),
            AVG(total_pymnt),
            MAX(total_pymnt)
        FROM fact_loans 
        WHERE last_pymnt_date IS NULL;
    """)
    r71 = cursor.fetchone()
    p10 = (r71[0] == 71 and r71[1] == 55 and r71[2] == 55)
    results['check_10_missing_last_pymnt_71'] = {
        'passed': p10, 'count': r71[0], 'has_payments': r71[1],
        'has_recoveries': r71[2], 'avg_pymnt': round(float(r71[3]), 2), 'max_pymnt': round(float(r71[4]), 2)
    }
    logger.info(f"Check 10 - 71 Null Payment Loans: count={r71[0]}, total_pymnt>0={r71[1]}, recoveries>0={r71[2]}, avg=${float(r71[3]):.2f}, max=${float(r71[4]):.2f} -> {'PASS' if p10 else 'FAIL'}")
    if not p10: all_passed = False

    # Check 11: Idempotency check (no duplicates)
    cursor.execute("SELECT loan_id, COUNT(*) FROM fact_loans GROUP BY loan_id HAVING COUNT(*) > 1;")
    dups = cursor.fetchall()
    p11 = (len(dups) == 0)
    results['check_11_no_duplicate_loans'] = {'passed': p11, 'duplicate_count': len(dups)}
    logger.info(f"Check 11 - Loan Idempotency: {len(dups)} duplicate loans found -> {'PASS' if p11 else 'FAIL'}")
    if not p11: all_passed = False

    cursor.close()
    logger.info("=" * 60)
    logger.info(f"VALIDATION SUMMARY: {'ALL CHECKS PASSED' if all_passed else 'SOME CHECKS FAILED'}")
    logger.info("=" * 60)
    return all_passed, results


def run_dry_run_validation(csv_path):
    """
    Run complete pre-flight data extraction, schema mapping, and validation
    using an in-memory database to verify the full ETL pipeline without requiring MySQL.
    """
    import sqlite3
    logger.info("=" * 60)
    logger.info("STARTING PIPELINE DRY-RUN / INTEGRITY VERIFICATION")
    logger.info("=" * 60)

    df = validate_source_csv(csv_path)

    # In-memory validation database
    conn = sqlite3.connect(":memory:")
    conn.execute("PRAGMA foreign_keys = ON;")
    cur = conn.cursor()

    # Create tables
    cur.execute("""
    CREATE TABLE dim_dates (
        calendar_date TEXT PRIMARY KEY,
        date_key INTEGER NOT NULL UNIQUE,
        year INTEGER NOT NULL,
        quarter INTEGER NOT NULL,
        month INTEGER NOT NULL,
        month_name TEXT NOT NULL,
        month_short_name TEXT NOT NULL,
        year_month TEXT NOT NULL,
        day INTEGER NOT NULL,
        day_name TEXT NOT NULL,
        is_weekend INTEGER NOT NULL
    );
    """)

    cur.execute("""
    CREATE TABLE dim_borrowers (
        borrower_key INTEGER PRIMARY KEY AUTOINCREMENT,
        member_id INTEGER NOT NULL UNIQUE,
        emp_title TEXT,
        emp_length TEXT,
        home_ownership TEXT NOT NULL,
        annual_inc REAL NOT NULL,
        verification_status TEXT NOT NULL,
        zip_code TEXT NOT NULL,
        addr_state TEXT NOT NULL,
        dti REAL NOT NULL,
        earliest_cr_line TEXT,
        open_acc INTEGER NOT NULL,
        total_acc INTEGER NOT NULL,
        revol_bal REAL NOT NULL,
        revol_util REAL,
        pub_rec INTEGER NOT NULL,
        pub_rec_bankruptcies INTEGER,
        delinq_2yrs INTEGER NOT NULL,
        inq_last_6mths INTEGER NOT NULL,
        mths_since_last_delinq INTEGER,
        mths_since_last_record INTEGER,
        collections_12_mths_ex_med INTEGER,
        chargeoff_within_12_mths INTEGER,
        delinq_amnt REAL NOT NULL,
        tax_liens INTEGER,
        acc_now_delinq INTEGER NOT NULL,
        FOREIGN KEY (earliest_cr_line) REFERENCES dim_dates(calendar_date)
    );
    """)

    cur.execute("""
    CREATE TABLE dim_loan_details (
        loan_detail_key INTEGER PRIMARY KEY AUTOINCREMENT,
        loan_id INTEGER NOT NULL UNIQUE,
        term TEXT NOT NULL,
        loan_term_months INTEGER NOT NULL,
        grade TEXT NOT NULL,
        sub_grade TEXT NOT NULL,
        int_rate REAL NOT NULL,
        installment REAL NOT NULL,
        purpose TEXT NOT NULL,
        title TEXT,
        description TEXT,
        initial_list_status TEXT NOT NULL,
        application_type TEXT NOT NULL,
        pymnt_plan TEXT NOT NULL,
        policy_code INTEGER NOT NULL,
        url TEXT
    );
    """)

    cur.execute("""
    CREATE TABLE fact_loans (
        loan_key INTEGER PRIMARY KEY AUTOINCREMENT,
        loan_id INTEGER NOT NULL UNIQUE,
        borrower_key INTEGER NOT NULL,
        loan_detail_key INTEGER NOT NULL,
        issue_date TEXT NOT NULL,
        last_pymnt_date TEXT,
        next_pymnt_date TEXT,
        last_credit_pull_date TEXT,
        loan_status TEXT NOT NULL,
        is_terminal_status INTEGER NOT NULL,
        is_charged_off INTEGER,
        loan_amnt REAL NOT NULL,
        funded_amnt REAL NOT NULL,
        funded_amnt_inv REAL NOT NULL,
        total_pymnt REAL NOT NULL,
        total_pymnt_inv REAL NOT NULL,
        total_rec_prncp REAL NOT NULL,
        total_rec_int REAL NOT NULL,
        total_rec_late_fee REAL NOT NULL,
        last_pymnt_amnt REAL NOT NULL,
        out_prncp REAL NOT NULL,
        out_prncp_inv REAL NOT NULL,
        recoveries REAL NOT NULL,
        collection_recovery_fee REAL NOT NULL,
        net_recoveries REAL NOT NULL,
        loan_to_income_ratio REAL NOT NULL,
        principal_recovery_ratio REAL NOT NULL,
        interest_to_funded_ratio REAL NOT NULL,
        FOREIGN KEY (borrower_key) REFERENCES dim_borrowers(borrower_key),
        FOREIGN KEY (loan_detail_key) REFERENCES dim_loan_details(loan_detail_key),
        FOREIGN KEY (issue_date) REFERENCES dim_dates(calendar_date),
        FOREIGN KEY (last_pymnt_date) REFERENCES dim_dates(calendar_date),
        FOREIGN KEY (next_pymnt_date) REFERENCES dim_dates(calendar_date),
        FOREIGN KEY (last_credit_pull_date) REFERENCES dim_dates(calendar_date)
    );
    """)

    dates_df = generate_dim_dates()
    dates_df.to_sql("dim_dates", conn, if_exists="append", index=False)

    borrower_cols = [
        'member_id', 'emp_title', 'emp_length', 'home_ownership', 'annual_inc',
        'verification_status', 'zip_code', 'addr_state', 'dti', 'earliest_cr_line',
        'open_acc', 'total_acc', 'revol_bal', 'revol_util', 'pub_rec',
        'pub_rec_bankruptcies', 'delinq_2yrs', 'inq_last_6mths',
        'mths_since_last_delinq', 'mths_since_last_record',
        'collections_12_mths_ex_med', 'chargeoff_within_12_mths',
        'delinq_amnt', 'tax_liens', 'acc_now_delinq'
    ]
    df[borrower_cols].to_sql("dim_borrowers", conn, if_exists="append", index=False)

    b_map = pd.read_sql("SELECT borrower_key, member_id FROM dim_borrowers", conn)
    b_dict = dict(zip(b_map['member_id'], b_map['borrower_key']))

    detail_cols = [
        'id', 'term', 'loan_term_months', 'grade', 'sub_grade', 'int_rate',
        'installment', 'purpose', 'title', 'desc', 'initial_list_status',
        'application_type', 'pymnt_plan', 'policy_code', 'url'
    ]
    details_df = df[detail_cols].rename(columns={'id': 'loan_id', 'desc': 'description'})
    details_df.to_sql("dim_loan_details", conn, if_exists="append", index=False)

    d_map = pd.read_sql("SELECT loan_detail_key, loan_id FROM dim_loan_details", conn)
    d_dict = dict(zip(d_map['loan_id'], d_map['loan_detail_key']))

    fact_df = pd.DataFrame()
    fact_df['loan_id'] = df['id']
    fact_df['borrower_key'] = df['member_id'].map(b_dict)
    fact_df['loan_detail_key'] = df['id'].map(d_dict)
    fact_df['issue_date'] = df['issue_d']
    fact_df['last_pymnt_date'] = df['last_pymnt_d']
    fact_df['next_pymnt_date'] = df['next_pymnt_d']
    fact_df['last_credit_pull_date'] = df['last_credit_pull_d']
    fact_df['loan_status'] = df['loan_status']
    fact_df['is_terminal_status'] = df['is_terminal_status']
    fact_df['is_charged_off'] = df['is_charged_off']
    fact_df['loan_amnt'] = df['loan_amnt']
    fact_df['funded_amnt'] = df['funded_amnt']
    fact_df['funded_amnt_inv'] = df['funded_amnt_inv']
    fact_df['total_pymnt'] = df['total_pymnt']
    fact_df['total_pymnt_inv'] = df['total_pymnt_inv']
    fact_df['total_rec_prncp'] = df['total_rec_prncp']
    fact_df['total_rec_int'] = df['total_rec_int']
    fact_df['total_rec_late_fee'] = df['total_rec_late_fee']
    fact_df['last_pymnt_amnt'] = df['last_pymnt_amnt']
    fact_df['out_prncp'] = df['out_prncp']
    fact_df['out_prncp_inv'] = df['out_prncp_inv']
    fact_df['recoveries'] = df['recoveries']
    fact_df['collection_recovery_fee'] = df['collection_recovery_fee']
    fact_df['net_recoveries'] = df['net_recoveries']
    fact_df['loan_to_income_ratio'] = df['loan_to_income_ratio']
    fact_df['principal_recovery_ratio'] = df['principal_recovery_ratio']
    fact_df['interest_to_funded_ratio'] = df['interest_to_funded_ratio']

    fact_df.to_sql("fact_loans", conn, if_exists="append", index=False)

    passed, results = validate_database_load(conn, df)
    conn.close()
    return passed, results


def main():
    parser = argparse.ArgumentParser(description="CredX Phase 4 MySQL Ingestion & Validation Pipeline")
    parser.add_argument("--csv", default=DEFAULT_CSV_PATH, help="Path to cleaned loan CSV")
    parser.add_argument("--batch-size", type=int, default=5000, help="Batch size for database inserts")
    parser.add_argument("--test-idempotency", action="store_true", help="Execute an explicit second loading pass to verify idempotency and zero duplicates")
    parser.add_argument("--dry-run", action="store_true", help="Perform complete pre-flight and ETL verification locally without connecting to MySQL")
    parser.add_argument("--validate-only", action="store_true", help="Run validation suite on existing database without re-loading")
    parser.add_argument("--force", action="store_true", help="Truncate existing tables before re-loading")
    args = parser.parse_args()

    if args.dry_run:
        passed, _ = run_dry_run_validation(args.csv)
        if passed:
            logger.info("Dry-run completed successfully! All data structures and validations are verified.")
            sys.exit(0)
        else:
            logger.error("Dry-run failed! Please inspect log output.")
            sys.exit(1)

    # Attempt MySQL connection
    conn = get_mysql_connection()
    if conn is None:
        logger.warning("\n" + "=" * 60)
        logger.warning("MYSQL IS CURRENTLY UNAVAILABLE OR CREDENTIALS ARE NOT CONFIGURED.")
        logger.warning("To connect to MySQL:")
        logger.warning("1. Create .env from .env.example: cp .env.example .env")
        logger.warning("2. Set MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE in .env")
        logger.warning("3. Re-run: python notebooks/load_data_to_mysql.py")
        logger.warning("Alternatively, run: python notebooks/load_data_to_mysql.py --dry-run")
        logger.warning("=" * 60)
        sys.exit(2)

    try:
        df = validate_source_csv(args.csv)

        if args.validate_only:
            passed, _ = validate_database_load(conn, df)
            conn.close()
            sys.exit(0 if passed else 1)

        # Ensure schema exists
        execute_ddl_script(conn, SCHEMA_SQL_PATH)

        # Check existing data
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM fact_loans;")
        existing_facts = cursor.fetchone()[0]
        cursor.close()

        if existing_facts > 0 and not args.force and not args.test_idempotency:
            logger.info(f"Database already contains {existing_facts:,} fact rows. Running validations directly...")
            passed, _ = validate_database_load(conn, df)
            conn.close()
            sys.exit(0 if passed else 1)

        if existing_facts > 0 and args.force:
            logger.warning("Force flag set. Truncating existing tables...")
            cursor = conn.cursor()
            cursor.execute("SET foreign_key_checks = 0;")
            cursor.execute("TRUNCATE TABLE fact_loans;")
            cursor.execute("TRUNCATE TABLE dim_borrowers;")
            cursor.execute("TRUNCATE TABLE dim_loan_details;")
            cursor.execute("TRUNCATE TABLE dim_dates;")
            cursor.execute("SET foreign_key_checks = 1;")
            conn.commit()
            cursor.close()

        logger.info("Beginning ETL loading process inside managed transaction...")
        dates_df = generate_dim_dates()
        load_dim_dates(conn, dates_df, args.batch_size)
        load_dim_borrowers(conn, df, args.batch_size)
        load_dim_loan_details(conn, df, args.batch_size)
        load_fact_loans(conn, df, args.batch_size)

        if args.test_idempotency:
            logger.info("Executing second pass of loader to verify idempotency (zero duplicates)...")
            load_fact_loans(conn, df, args.batch_size)
            logger.info("Second pass completed successfully.")

        # Validate before committing
        passed, results = validate_database_load(conn, df)
        if passed:
            logger.info("All validations passed! Committing transaction to MySQL...")
            conn.commit()
            logger.info("Ingestion completed and verified successfully!")
        else:
            logger.error("Validation failed! Rolling back transaction...")
            conn.rollback()
            sys.exit(1)

    except Exception as e:
        logger.error(f"Unexpected error during ingestion: {e}")
        if conn and conn.is_connected():
            logger.info("Rolling back active transaction...")
            conn.rollback()
        raise
    finally:
        if conn and conn.is_connected():
            conn.close()
            logger.info("MySQL connection closed.")


if __name__ == "__main__":
    main()
