-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 4: Database Design & Relational Star Schema DDL
-- File: sql/01_create_schema.sql
-- Target DBMS: MySQL 8.0+ (InnoDB)
-- ==============================================================================

-- Setup Instructions:
-- Run this script in MySQL Workbench, MySQL CLI, or through the automated loader.
-- If you need to create the database first, run:
--     CREATE DATABASE IF NOT EXISTS credx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
--     USE credx;

-- Ensure foreign key checks are enabled
SET foreign_key_checks = 1;

-- ==============================================================================
-- 1. DIMENSION TABLE: dim_dates (Conformed Date Dimension)
-- Grain: One row per calendar date (Daily granularity: 1946-01-01 to 2016-12-31)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS dim_dates (
    `calendar_date`     DATE NOT NULL,
    `date_key`          INT NOT NULL,
    `year`              SMALLINT NOT NULL,
    `quarter`           TINYINT NOT NULL,
    `month`             TINYINT NOT NULL,
    `month_name`        VARCHAR(15) NOT NULL,
    `month_short_name`  VARCHAR(3) NOT NULL,
    `year_month`        VARCHAR(7) NOT NULL,
    `day`               TINYINT NOT NULL,
    `day_name`          VARCHAR(15) NOT NULL,
    `is_weekend`        TINYINT NOT NULL DEFAULT 0,
    
    PRIMARY KEY (`calendar_date`),
    UNIQUE KEY `uq_dim_dates_key` (`date_key`),
    INDEX `idx_dim_dates_year` (`year`),
    INDEX `idx_dim_dates_ym` (`year_month`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Conformed Date Dimension supporting role-playing dates (origination, repayment, credit line)';

-- ==============================================================================
-- 2. DIMENSION TABLE: dim_borrowers
-- Grain: One row per unique borrower (member_id)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS dim_borrowers (
    borrower_key                INT AUTO_INCREMENT NOT NULL,
    member_id                   INT NOT NULL,
    emp_title                   VARCHAR(100) NULL,
    emp_length                  VARCHAR(20) NULL,
    home_ownership              VARCHAR(20) NOT NULL,
    annual_inc                  DECIMAL(12,2) NOT NULL,
    verification_status         VARCHAR(50) NOT NULL,
    zip_code                    VARCHAR(10) NOT NULL,
    addr_state                  VARCHAR(5) NOT NULL,
    dti                         DECIMAL(6,2) NOT NULL,
    earliest_cr_line            DATE NULL,
    open_acc                    INT NOT NULL,
    total_acc                   INT NOT NULL,
    revol_bal                   DECIMAL(12,2) NOT NULL,
    revol_util                  DECIMAL(5,2) NULL,
    pub_rec                     INT NOT NULL,
    pub_rec_bankruptcies        INT NULL,
    delinq_2yrs                 INT NOT NULL,
    inq_last_6mths              INT NOT NULL,
    mths_since_last_delinq      INT NULL,
    mths_since_last_record      INT NULL,
    collections_12_mths_ex_med  INT NULL,
    chargeoff_within_12_mths    INT NULL,
    delinq_amnt                 DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    tax_liens                   INT NULL,
    acc_now_delinq              INT NOT NULL DEFAULT 0,

    PRIMARY KEY (borrower_key),
    UNIQUE KEY uq_borrower_member_id (member_id),
    CONSTRAINT fk_borrower_earliest_cr_line FOREIGN KEY (earliest_cr_line) 
        REFERENCES dim_dates(calendar_date) ON DELETE RESTRICT ON UPDATE CASCADE,
    INDEX idx_borrower_state (addr_state),
    INDEX idx_borrower_home (home_ownership),
    INDEX idx_borrower_income (annual_inc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Borrower Dimension: Demographics, employment, income verification, and credit bureau history';

-- ==============================================================================
-- 3. DIMENSION TABLE: dim_loan_details
-- Grain: One row per loan underwriting and contract profile (loan_id)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS dim_loan_details (
    loan_detail_key             INT AUTO_INCREMENT NOT NULL,
    loan_id                     INT NOT NULL,
    term                        VARCHAR(20) NOT NULL,
    loan_term_months            SMALLINT NOT NULL,
    grade                       VARCHAR(2) NOT NULL,
    sub_grade                   VARCHAR(5) NOT NULL,
    int_rate                    DECIMAL(5,2) NOT NULL,
    installment                 DECIMAL(10,2) NOT NULL,
    purpose                     VARCHAR(50) NOT NULL,
    title                       VARCHAR(255) NULL,
    description                 TEXT NULL,
    initial_list_status         VARCHAR(5) NOT NULL,
    application_type            VARCHAR(20) NOT NULL,
    pymnt_plan                  VARCHAR(5) NOT NULL,
    policy_code                 INT NOT NULL,
    url                         VARCHAR(255) NULL,

    PRIMARY KEY (loan_detail_key),
    UNIQUE KEY uq_loan_details_loan_id (loan_id),
    INDEX idx_loan_details_grade (grade),
    INDEX idx_loan_details_subgrade (sub_grade),
    INDEX idx_loan_details_purpose (purpose),
    INDEX idx_loan_details_term (loan_term_months)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Loan Underwriting & Terms Dimension: Pricing, grading, contract structure, and metadata';

-- ==============================================================================
-- 4. FACT TABLE: fact_loans
-- Grain: One row per loan transaction / account (loan_id)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS fact_loans (
    loan_key                    INT AUTO_INCREMENT NOT NULL,
    loan_id                     INT NOT NULL,
    borrower_key                INT NOT NULL,
    loan_detail_key             INT NOT NULL,
    
    -- Role-Playing Date Foreign Keys
    issue_date                  DATE NOT NULL,
    last_pymnt_date             DATE NULL,
    next_pymnt_date             DATE NULL,
    last_credit_pull_date       DATE NULL,
    
    -- Loan Outcome & Status Flags
    loan_status                 VARCHAR(20) NOT NULL,
    is_terminal_status          TINYINT NOT NULL,
    is_charged_off              TINYINT NULL,
    
    -- Financial Measures: Origination
    loan_amnt                   DECIMAL(10,2) NOT NULL,
    funded_amnt                 DECIMAL(10,2) NOT NULL,
    funded_amnt_inv             DECIMAL(10,2) NOT NULL,
    
    -- Financial Measures: Cash Inflows / Repayment
    total_pymnt                 DECIMAL(10,2) NOT NULL,
    total_pymnt_inv             DECIMAL(10,2) NOT NULL,
    total_rec_prncp             DECIMAL(10,2) NOT NULL,
    total_rec_int               DECIMAL(10,2) NOT NULL,
    total_rec_late_fee          DECIMAL(10,2) NOT NULL,
    last_pymnt_amnt             DECIMAL(10,2) NOT NULL,
    
    -- Financial Measures: Balances & Recoveries
    out_prncp                   DECIMAL(10,2) NOT NULL,
    out_prncp_inv               DECIMAL(10,2) NOT NULL,
    recoveries                  DECIMAL(10,2) NOT NULL,
    collection_recovery_fee     DECIMAL(10,2) NOT NULL,
    net_recoveries              DECIMAL(10,2) NOT NULL,
    
    -- Derived Analytical Ratios
    loan_to_income_ratio        DECIMAL(7,4) NOT NULL,
    principal_recovery_ratio    DECIMAL(7,4) NOT NULL,
    interest_to_funded_ratio    DECIMAL(7,4) NOT NULL,

    PRIMARY KEY (loan_key),
    UNIQUE KEY uq_fact_loans_loan_id (loan_id),
    
    -- Foreign Key Constraints
    CONSTRAINT fk_fact_borrower FOREIGN KEY (borrower_key) 
        REFERENCES dim_borrowers(borrower_key) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fact_loan_detail FOREIGN KEY (loan_detail_key) 
        REFERENCES dim_loan_details(loan_detail_key) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fact_issue_date FOREIGN KEY (issue_date) 
        REFERENCES dim_dates(calendar_date) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fact_last_pymnt_date FOREIGN KEY (last_pymnt_date) 
        REFERENCES dim_dates(calendar_date) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fact_next_pymnt_date FOREIGN KEY (next_pymnt_date) 
        REFERENCES dim_dates(calendar_date) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_fact_last_credit_pull_date FOREIGN KEY (last_credit_pull_date) 
        REFERENCES dim_dates(calendar_date) ON DELETE RESTRICT ON UPDATE CASCADE,
        
    -- Analytical Indexes
    INDEX idx_fact_borrower_key (borrower_key),
    INDEX idx_fact_loan_detail_key (loan_detail_key),
    INDEX idx_fact_issue_date (issue_date),
    INDEX idx_fact_loan_status (loan_status),
    INDEX idx_fact_is_charged_off (is_charged_off),
    INDEX idx_fact_is_terminal (is_terminal_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Fact Table: Loan-level financial amounts, cash flows, repayment performance, and outcome indicators';
