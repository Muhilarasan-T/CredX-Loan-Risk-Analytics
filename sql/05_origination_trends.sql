-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 05. Origination Trends
-- File: sql/05_origination_trends.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 5.1: Annual Loan Origination Velocity and Year-over-Year Growth
-- Business Question:
--   How rapidly did the LendingClub lending platform scale annual origination
--   volume and funded capital between 2007 and 2011?
-- Explanation:
--   Uses LAG() window functions to compute Year-over-Year (YoY) percentage growth
--   in both loan origination count and funded volume.
-- ------------------------------------------------------------------------------
WITH yearly_originations AS (
    SELECT 
        d.`year`                                        AS origination_year,
        COUNT(*)                                        AS loans_issued,
        SUM(f.funded_amnt)                              AS total_capital_funded,
        ROUND(AVG(f.funded_amnt), 2)                    AS avg_loan_size,
        ROUND(AVG(ld.int_rate), 2)                      AS avg_interest_rate
    FROM fact_loans f
    JOIN dim_dates d ON f.issue_date = d.calendar_date
    JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
    GROUP BY d.`year`
)
SELECT 
    origination_year,
    loans_issued,
    LAG(loans_issued, 1) OVER (ORDER BY origination_year) AS prev_year_loans,
    ROUND(
        (loans_issued - LAG(loans_issued, 1) OVER (ORDER BY origination_year)) * 100.0 / 
        NULLIF(LAG(loans_issued, 1) OVER (ORDER BY origination_year), 0), 
        2
    )                                                   AS yoy_loan_count_growth_pct,
    total_capital_funded,
    LAG(total_capital_funded, 1) OVER (ORDER BY origination_year) AS prev_year_capital,
    ROUND(
        (total_capital_funded - LAG(total_capital_funded, 1) OVER (ORDER BY origination_year)) * 100.0 / 
        NULLIF(LAG(total_capital_funded, 1) OVER (ORDER BY origination_year), 0), 
        2
    )                                                   AS yoy_capital_growth_pct,
    avg_loan_size,
    avg_interest_rate
FROM yearly_originations
ORDER BY origination_year ASC;


-- ------------------------------------------------------------------------------
-- Query 5.2: Vintage Cohort Credit Quality & Default Evolution
-- Business Question:
--   How did underwriting quality evolve across vintage origination cohorts
--   (2007 through 2011)? Did rapid volume expansion dilute credit standards?
-- Explanation:
--   Analyzes vintage cohorts by origination year, calculating the terminal default
--   rate, average borrower income, average credit score proxy (interest rate),
--   and total cash multiple returned per vintage.
-- ------------------------------------------------------------------------------
SELECT 
    d.`year`                                            AS vintage_year,
    COUNT(*)                                            AS total_originated_loans,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    SUM(f.is_terminal_status)                           AS terminal_loans,
    SUM(CASE WHEN f.loan_status = 'Current' THEN 1 ELSE 0 END) AS active_current_loans,
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    -- Vintage closed-cohort default rate
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS vintage_charge_off_rate_pct,
    ROUND(AVG(ld.int_rate), 2)                          AS avg_interest_rate,
    ROUND(AVG(b.annual_inc), 2)                         AS avg_borrower_income,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS vintage_cash_return_multiple
FROM fact_loans f
JOIN dim_dates d ON f.issue_date = d.calendar_date
JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
GROUP BY d.`year`
ORDER BY d.`year` ASC;


-- ------------------------------------------------------------------------------
-- Query 5.3: Monthly Time-Series with Running Cumulative Capital Deployed
-- Business Question:
--   What was the monthly capital deployment progression and cumulative platform
--   volume across the entire 55-month operating period?
-- Explanation:
--   Computes monthly loan volume, funded amount, cumulative running totals,
--   and 3-month trailing moving average of funded capital.
-- ------------------------------------------------------------------------------
WITH monthly_data AS (
    SELECT 
        d.`year_month`                                  AS origination_period,
        f.issue_date,
        COUNT(*)                                        AS monthly_loans,
        SUM(f.funded_amnt)                              AS monthly_funded_amount,
        ROUND(AVG(f.funded_amnt), 2)                    AS avg_monthly_loan_size
    FROM fact_loans f
    JOIN dim_dates d ON f.issue_date = d.calendar_date
    GROUP BY d.`year_month`, f.issue_date
)
SELECT 
    origination_period,
    monthly_loans,
    monthly_funded_amount,
    -- Running cumulative total of funded capital
    SUM(monthly_funded_amount) OVER (
        ORDER BY issue_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS cumulative_funded_capital,
    -- Running cumulative total of loan count
    SUM(monthly_loans) OVER (
        ORDER BY issue_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS cumulative_loan_count,
    -- 3-Month Moving Average of capital deployment
    ROUND(
        AVG(monthly_funded_amount) OVER (
            ORDER BY issue_date 
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 
        2
    )                                                   AS rolling_3month_avg_capital
FROM monthly_data
ORDER BY issue_date ASC;
