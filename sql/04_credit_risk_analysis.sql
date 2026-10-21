-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 04. Credit Risk Analysis
-- File: sql/04_credit_risk_analysis.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 4.1: Credit Risk & Profitability Across Credit Grades (A through G)
-- Business Question:
--   How accurately does LendingClub's proprietary grading hierarchy (Grade A to G)
--   predict default risk, and does higher interest compensation offset the default losses?
-- Explanation:
--   Computes terminal charge-off rate using the exact closed-cohort denominator
--   (excluding Current loans), average interest rate, total funded capital,
--   and aggregate cash return multiple across each risk grade.
-- ------------------------------------------------------------------------------
SELECT 
    d.grade,
    COUNT(*)                                            AS total_loans,
    SUM(f.is_terminal_status)                           AS terminal_loans,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    -- Strictly correct closed-cohort default rate
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(AVG(d.int_rate), 2)                           AS avg_interest_rate_pct,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    SUM(f.total_pymnt)                                  AS total_cash_collected,
    -- Net portfolio cash return multiple per grade
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
GROUP BY d.grade
ORDER BY d.grade ASC;


-- ------------------------------------------------------------------------------
-- Query 4.2: Credit Risk Profiling Across Loan Purposes
-- Business Question:
--   Which borrowing purposes exhibit the highest default rates, and which
--   represent the safest capital deployment?
-- Explanation:
--   Groups portfolio by loan purpose category to compute total volume,
--   funded capital, average debt-to-income (DTI) ratio, and terminal default rate.
-- ------------------------------------------------------------------------------
SELECT 
    d.purpose,
    COUNT(*)                                            AS total_loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS purpose_loan_share_pct,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_loan_size,
    ROUND(AVG(b.dti), 2)                                AS avg_borrower_dti,
    ROUND(AVG(d.int_rate), 2)                           AS avg_interest_rate_pct,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY d.purpose
ORDER BY terminal_charge_off_rate_pct DESC;


-- ------------------------------------------------------------------------------
-- Query 4.3: Risk-Based Pricing: Default Rates Across Interest Rate Tiers
-- Business Question:
--   How strongly does the assigned interest rate correlate with default frequency,
--   and are the highest interest rate bands generating net positive returns?
-- Explanation:
--   Segments loans into 5 percentage-point interest rate brackets and evaluates
--   the terminal charge-off rate and aggregate cash return multiple.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN d.int_rate < 10.00 THEN '1. Low (< 10%)'
        WHEN d.int_rate BETWEEN 10.00 AND 12.99 THEN '2. Medium-Low (10% - 12.99%)'
        WHEN d.int_rate BETWEEN 13.00 AND 15.99 THEN '3. Medium-High (13% - 15.99%)'
        WHEN d.int_rate BETWEEN 16.00 AND 19.99 THEN '4. High (16% - 19.99%)'
        ELSE '5. Very High (20%+)'
    END                                                 AS interest_rate_tier,
    COUNT(*)                                            AS total_loans,
    ROUND(AVG(d.int_rate), 2)                           AS avg_interest_rate,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    SUM(f.total_pymnt)                                  AS total_payments_collected,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
GROUP BY interest_rate_tier
ORDER BY interest_rate_tier ASC;


-- ------------------------------------------------------------------------------
-- Query 4.4: Borrower Debt Burden: Risk by Debt-to-Income (DTI) Bands
-- Business Question:
--   At what debt-to-income threshold does borrower default risk escalate significantly?
-- Explanation:
--   Segments borrowers by DTI ratio into 5-point bins and analyzes the relationship
--   between leverage and default frequency.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN b.dti < 5.00 THEN '1. DTI < 5%'
        WHEN b.dti BETWEEN 5.00 AND 9.99 THEN '2. DTI 5% - 9.99%'
        WHEN b.dti BETWEEN 10.00 AND 14.99 THEN '3. DTI 10% - 14.99%'
        WHEN b.dti BETWEEN 15.00 AND 19.99 THEN '4. DTI 15% - 19.99%'
        WHEN b.dti BETWEEN 20.00 AND 24.99 THEN '5. DTI 20% - 24.99%'
        ELSE '6. DTI 25%+'
    END                                                 AS dti_bracket,
    COUNT(*)                                            AS total_loans,
    ROUND(AVG(b.dti), 2)                                AS avg_dti,
    ROUND(AVG(b.annual_inc), 2)                         AS avg_annual_income,
    ROUND(AVG(f.loan_to_income_ratio), 4)               AS avg_loan_to_income,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct
FROM fact_loans f
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY dti_bracket
ORDER BY dti_bracket ASC;


-- ------------------------------------------------------------------------------
-- Query 4.5: Loan Amount Tiers vs. Default Rate and Capital Exposure
-- Business Question:
--   Are larger loan requests riskier than smaller loans, and what is the
--   charge-off exposure concentrated in large loans?
-- Explanation:
--   Segments funded loan amounts into $5k brackets to evaluate whether ticket size
--   correlates with higher probability of default.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN f.funded_amnt < 5000 THEN '1. Under $5,000'
        WHEN f.funded_amnt BETWEEN 5000 AND 9999 THEN '2. $5,000 - $9,999'
        WHEN f.funded_amnt BETWEEN 10000 AND 14999 THEN '3. $10,000 - $14,999'
        WHEN f.funded_amnt BETWEEN 15000 AND 19999 THEN '4. $15,000 - $19,999'
        WHEN f.funded_amnt BETWEEN 20000 AND 24999 THEN '5. $20,000 - $24,999'
        ELSE '6. $25,000+'
    END                                                 AS loan_size_tier,
    COUNT(*)                                            AS total_loans,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    ROUND(SUM(f.funded_amnt) * 100.0 / SUM(SUM(f.funded_amnt)) OVER (), 2) AS capital_share_pct,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
GROUP BY loan_size_tier
ORDER BY loan_size_tier ASC;
