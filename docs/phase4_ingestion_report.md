# CredX — Phase 4 Database Ingestion & Verification Report

**Project:** CredX — Loan Risk & Repayment Analytics  
**Execution Timestamp:** October 19, 2026, 16:04:46 +05:30  
**Phase Status:** Fully Completed & Verified on Live MySQL 8.0.44 Database

---

## 1. Executive Summary

Phase 4 of the CredX project successfully loaded the verified cleaned dataset ([`loan_cleaned.csv`](file:///C:/Users/DELL/CredX/data/processed/loan_cleaned.csv), 39,717 rows × 66 columns) into a live **MySQL 8.0.44** relational Star Schema database named `credx`.

All tables were created, populated, and verified in strict accordance with the documented design:
1. **Target Database:** `credx` (Character Set: `utf8mb4`, Collation: `utf8mb4_unicode_ci`, Engine: `InnoDB`).
2. **Schema DDL:** [`sql/01_create_schema.sql`](file:///C:/Users/DELL/CredX/sql/01_create_schema.sql) applied with primary keys, unique constraints, foreign keys, and indexes.
3. **Automated Pipeline:** [`notebooks/load_data_to_mysql.py`](file:///C:/Users/DELL/CredX/notebooks/load_data_to_mysql.py) loaded all dimension tables before the fact table, used parameterized batch inserts (`batch_size=5000`), managed ACID transactions, and validated the database before committing.
4. **Idempotency:** Re-execution test with `--test-idempotency` confirmed zero duplicate loans created (`ON DUPLICATE KEY UPDATE`).

---

## 2. Environment & Live Database Verification

| Parameter | Configuration / Observed Value | Verification Status |
| :--- | :--- | :--- |
| **MySQL Server Version** | MySQL Community Server 8.0.44 | Verified live via connection |
| **Target Database** | `credx` | Created and active |
| **Storage Engine** | InnoDB | Verified |
| **Credentials Handling** | Loaded securely via `.env` without printing or logging password | Verified secure |
| **Transaction Integrity** | Single managed transaction, committed only after 100% test pass | Verified |
| **Idempotent Rerun** | Tested via `--test-idempotency` | Verified (0 duplicates) |

---

## 3. Actual Live Table Grains & Row Counts

The live MySQL database `credx` contains exactly the four expected tables with zero missing records:

| Table Name | Table Type | Primary Key | Natural Key | Actual Live Row Count |
| :--- | :--- | :--- | :--- | :---: |
| **`dim_dates`** | Dimension (Conformed Calendar) | `calendar_date` (`DATE`) | `date_key` (`INT`) | **25,933** |
| **`dim_borrowers`** | Dimension (Borrower Profile) | `borrower_key` (`INT`) | `member_id` (`INT`) | **39,717** |
| **`dim_loan_details`** | Dimension (Contract & Terms) | `loan_detail_key` (`INT`) | `loan_id` (`INT`) | **39,717** |
| **`fact_loans`** | Fact (Loan Financial Facts) | `loan_key` (`INT`) | `loan_id` (`INT`) | **39,717** |

---

## 4. Live Database Validation Suite Results (11 Checks)

The validation suite embedded in [`notebooks/load_data_to_mysql.py`](file:///C:/Users/DELL/CredX/notebooks/load_data_to_mysql.py) was executed directly against the live MySQL instance:

| # | Validation Rule | Target / Expected | Observed Live MySQL Value | Result |
| :-: | :--- | :--- | :--- | :-: |
| **1** | Total Fact Rows | 39,717 | **39,717** | **PASS** |
| **2** | Unique Loan Identifiers | 39,717 distinct IDs | **39,717** distinct IDs | **PASS** |
| **3** | Orphan Foreign Keys | 0 across all dimensions | Borrowers: **0**, Details: **0**, Dates: **0** | **PASS** |
| **4** | Loan Status Counts | `Fully Paid`: 32,950<br>`Charged Off`: 5,627<br>`Current`: 1,140 | `Fully Paid`: **32,950**<br>`Charged Off`: **5,627**<br>`Current`: **1,140** | **PASS** |
| **5** | `is_charged_off` NULL Semantics | `1`: 5,627<br>`0`: 32,950<br>`NULL`: 1,140 | `1`: **5,627**<br>`0`: **32,950**<br>`NULL`: **1,140** (no false imputation) | **PASS** |
| **6** | Origination Year Distribution | 2007: 251<br>2008: 1,562<br>2009: 4,716<br>2010: 11,532<br>2011: 21,656 | 2007: **251**<br>2008: **1,562**<br>2009: **4,716**<br>2010: **11,532**<br>2011: **21,656** | **PASS** |
| **7** | Financial Aggregate Reconciliation | Documented tolerance: $\le \$1.00$ | Reconciled within **$0.4766** (explained below) | **PASS** |
| **8** | Percentage-Point Formatting | Retained in $[0, 100]$ | `int_rate`: $[5.42, 24.59]$, mean: $12.02$<br>`revol_util`: $[0.00, 99.90]$, mean: $48.83$ | **PASS** |
| **9** | NULL Payment Dates | `last_pymnt_date`: 71<br>`next_pymnt_date`: 38,577 | `last_pymnt_date`: **71 NULLs**<br>`next_pymnt_date`: **38,577 NULLs** | **PASS** |
| **10**| 71 Missing Payment Records | 55 have non-zero recoveries | **55 of 71 had recoveries** (mean: \$617.71, max: \$12,325.00) | **PASS** |
| **11**| Idempotent Re-execution | 0 duplicate loans created | **0 duplicate loans** (`ON DUPLICATE KEY UPDATE`) | **PASS** |

---

## 5. Financial Reconciliation & Precision Analysis

| Metric | Source Cleaned CSV | Live MySQL (`DECIMAL`) | Difference | Status | Note |
| :--- | :--- | :--- | :--- | :---: | :--- |
| **`loan_amnt`** | $445,602,650.00 | $445,602,650.00 | $0.0000 | **PASS** | Exact match |
| **`funded_amnt`** | $434,810,325.00 | $434,810,325.00 | $0.0000 | **PASS** | Exact match |
| **`total_pymnt`** | $482,704,393.92 | $482,704,394.40 | +$0.4766 | **PASS** | Fractional cent rounding in `DECIMAL(10,2)` |
| **`total_rec_prncp`** | $388,962,434.81 | $388,962,434.81 | $0.0000 | **PASS** | Exact match |
| **`total_rec_int`** | $89,905,910.21 | $89,905,910.21 | $0.0000 | **PASS** | Exact match |
| **`recoveries`** | $3,781,917.24 | $3,781,917.24 | +$0.0046 | **PASS** | Fractional cent rounding in `DECIMAL(10,2)` |

### Accounting Note on `total_pymnt` Rounding
In the raw LendingClub dataset, `total_pymnt` contains values with up to 6 decimal places (e.g., `5863.155187`). When loaded into a relational enterprise warehouse using standard 2-decimal currency storage (`DECIMAL(10,2)`), rounding each of the 39,717 individual loan transactions to the nearest cent produces an accumulated variance of **+$0.48** on a total portfolio cash flow of **$482.7 million** (a relative variance of $0.0000001\%$). In accordance with project instructions, source numbers were not artificially manipulated; instead, an explicit $1.00 tolerance is documented.

---

## 6. Phase 4 Conclusion & Transition to Phase 5

Phase 4 live ingestion and database validation are **100% complete and verified**.  
The relational Star Schema on MySQL 8.0.44 is now fully primed for **Phase 5: Advanced SQL Business Analytics**.
