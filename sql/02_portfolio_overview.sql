-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 02. Portfolio Overview
-- File: sql/02_portfolio_overview.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 2.1: Executive Portfolio KPI Summary
-- Business Question:
--   What is the total capital deployed, total repayment collected, and aggregate
--   cash flow balance across the historical 2007–2011 LendingClub portfolio?
-- Explanation:
--   Aggregates primary loan volume metrics, investor allocations, principal and
--   interest returns, and post-charge-off recoveries to provide the top-level
--   executive balance sheet of the lending platform.
-- ------------------------------------------------------------------------------
SELECT 
    COUNT(*)                                            AS total_loans_issued,
    SUM(loan_amnt)                                      AS total_loan_amnt_requested,
    SUM(funded_amnt)                                    AS total_capital_funded,
    SUM(funded_amnt_inv)                                AS total_investor_funded,
    SUM(total_pymnt)                                    AS total_payments_collected,
    SUM(total_rec_prncp)                                AS total_principal_collected,
    SUM(total_rec_int)                                  AS total_interest_collected,
    SUM(recoveries)                                     AS total_gross_recoveries,
    SUM(net_recoveries)                                 AS total_net_recoveries,
    ROUND(SUM(total_pymnt) - SUM(funded_amnt), 2)       AS net_portfolio_cash_profit,
    ROUND((SUM(total_pymnt) / SUM(funded_amnt) - 1.0) * 100, 2) AS total_portfolio_roi_pct
FROM fact_loans;


-- ------------------------------------------------------------------------------
-- Query 2.2: Portfolio Distribution by Loan Outcome (Loan Status)
-- Business Question:
--   How is the loan portfolio distributed across distinct outcome states
--   (Fully Paid, Charged Off, Current), and what volume of capital does each represent?
-- Explanation:
--   Calculates loan volume, portfolio share (%), funded capital, payment totals,
--   and average pricing (interest rate) across each loan status category.
-- ------------------------------------------------------------------------------
SELECT 
    f.loan_status,
    COUNT(*)                                            AS loan_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS loan_count_share_pct,
    SUM(f.funded_amnt)                                  AS total_funded_amount,
    ROUND(SUM(f.funded_amnt) * 100.0 / SUM(SUM(f.funded_amnt)) OVER (), 2) AS funded_amount_share_pct,
    SUM(f.total_pymnt)                                  AS total_payments_collected,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    ROUND(AVG(d.int_rate), 2)                           AS avg_interest_rate_pct
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
GROUP BY f.loan_status
ORDER BY loan_count DESC;


-- ------------------------------------------------------------------------------
-- Query 2.3: Terminal Closed Cohort vs. Active Loan Exposure
-- Business Question:
--   What proportion of the portfolio is completely resolved (terminal status)
--   versus still actively repaying (Current), and what is the definitive default rate?
-- Explanation:
--   Distinguishes resolved loans from ongoing loans. For credit risk benchmarking,
--   the true charge-off rate must use terminal loans as the denominator (38,577),
--   avoiding dilution from ongoing Current loans (1,140).
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN is_terminal_status = 1 THEN 'Terminal (Closed Cohort)'
        ELSE 'Active (Ongoing)'
    END                                                 AS portfolio_segment,
    COUNT(*)                                            AS loan_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS segment_share_pct,
    SUM(funded_amnt)                                    AS total_funded_capital,
    ROUND(SUM(funded_amnt) * 100.0 / SUM(SUM(funded_amnt)) OVER (), 2) AS capital_share_pct,
    SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        COUNT(*), 
        2
    )                                                   AS segment_charge_off_pct
FROM fact_loans
GROUP BY is_terminal_status;
