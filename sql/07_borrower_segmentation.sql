-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 07. Borrower & Portfolio Segmentation
-- File: sql/07_borrower_segmentation.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 7.1: Borrower Home Ownership Segmentation & Risk Profile
-- Business Question:
--   Does residential stability (home ownership status) correlate with repayment
--   reliability and lower default rates?
-- Explanation:
--   Segments portfolio by home ownership category (MORTGAGE, RENT, OWN, OTHER, NONE).
--   Calculates loan volume, average income, average debt-to-income (DTI) ratio,
--   and terminal charge-off rate.
-- ------------------------------------------------------------------------------
SELECT 
    b.home_ownership,
    COUNT(*)                                            AS total_loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS home_loan_share_pct,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    ROUND(AVG(b.annual_inc), 2)                         AS avg_annual_income,
    ROUND(AVG(b.dti), 2)                                AS avg_dti_ratio,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    -- Terminal charge-off rate
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY b.home_ownership
ORDER BY total_loans DESC;


-- ------------------------------------------------------------------------------
-- Query 7.2: Annual Income Tiers and Loan Affordability
-- Business Question:
--   How does borrower income level impact borrowing appetite, leverage
--   (loan-to-income ratio), and ultimate default probability?
-- Explanation:
--   Segments borrowers into 5 income bands. Analyzes the relationship between
--   income level, average loan size requested, loan-to-income leverage, and default.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN b.annual_inc < 35000 THEN '1. Low (< $35,000)'
        WHEN b.annual_inc BETWEEN 35000 AND 59999 THEN '2. Moderate ($35,000 - $59,999)'
        WHEN b.annual_inc BETWEEN 60000 AND 99999 THEN '3. Middle ($60,000 - $99,999)'
        WHEN b.annual_inc BETWEEN 100000 AND 149999 THEN '4. Upper-Middle ($100,000 - $149,999)'
        ELSE '5. High ($150,000+)'
    END                                                 AS income_tier,
    COUNT(*)                                            AS total_borrowers,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS borrower_share_pct,
    ROUND(AVG(b.annual_inc), 2)                         AS avg_annual_income,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    ROUND(AVG(f.loan_to_income_ratio), 4)               AS avg_loan_to_income_ratio,
    ROUND(AVG(b.dti), 2)                                AS avg_dti_ratio,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY income_tier
ORDER BY income_tier ASC;


-- ------------------------------------------------------------------------------
-- Query 7.3: Geographic Exposure: Top 10 States by Loan Capital & Risk
-- Business Question:
--   Which US states represent the highest concentration of funded loans,
--   and does default risk vary significantly across geographic regions?
-- Explanation:
--   Ranks the top 10 borrower states by total funded amount, displaying their
--   portfolio share, average funded capital, and terminal default rate.
-- ------------------------------------------------------------------------------
SELECT 
    b.addr_state                                        AS state_code,
    COUNT(*)                                            AS total_loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS state_loan_share_pct,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    ROUND(AVG(b.annual_inc), 2)                         AS avg_annual_income,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct
FROM fact_loans f
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY b.addr_state
ORDER BY total_funded_capital DESC
LIMIT 10;


-- ------------------------------------------------------------------------------
-- Query 7.4: Credit Bureau Derogatory History & Delinquency Impact
-- Business Question:
--   How dramatically does a prior derogatory record (past delinquency, public
--   record, or bankruptcy) elevate a borrower's likelihood of default?
-- Explanation:
--   Segments borrowers by historical bureau flags: 30+ days delinquency in last
--   2 years, derogatory public records, and reported bankruptcy filings.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN b.delinq_2yrs = 0 THEN '0 Delinquencies (Clean)'
        WHEN b.delinq_2yrs = 1 THEN '1 Delinquency'
        ELSE '2+ Delinquencies'
    END                                                 AS past_delinquency_status,
    CASE 
        WHEN b.pub_rec = 0 THEN 'No Derogatory Public Records'
        ELSE '1+ Derogatory Public Records'
    END                                                 AS public_record_status,
    COUNT(*)                                            AS total_loans,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(AVG(ld.int_rate), 2)                          AS avg_interest_rate
FROM fact_loans f
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
GROUP BY past_delinquency_status, public_record_status
ORDER BY past_delinquency_status ASC, public_record_status ASC;
