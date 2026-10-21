-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 06. Charge-Off and Recovery
-- File: sql/06_chargeoff_and_recovery.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 6.1: Macro Default Exposure and Loss Decomposition
-- Business Question:
--   What was the total capital exposed to default, how much principal was recovered
--   prior to write-off, and what is the net principal deficit across charged-off loans?
-- Explanation:
--   Decomposes the 5,627 charged-off loans into pre-default cash flows (principal,
--   interest), gross principal written off, and post-default recoveries.
-- ------------------------------------------------------------------------------
SELECT 
    COUNT(*)                                            AS charged_off_loans,
    SUM(funded_amnt)                                    AS gross_funded_capital_at_risk,
    SUM(total_rec_prncp)                                AS principal_collected_pre_default,
    -- Gross uncollected principal write-off
    ROUND(SUM(funded_amnt) - SUM(total_rec_prncp), 2)   AS uncollected_principal_deficit,
    SUM(total_rec_int)                                  AS interest_collected_pre_default,
    SUM(recoveries)                                     AS gross_post_default_recoveries,
    SUM(collection_recovery_fee)                        AS collection_fees_deducted,
    SUM(net_recoveries)                                 AS net_recoveries_realized,
    SUM(total_pymnt)                                    AS total_cash_collected,
    -- Net Economic Cash Loss = Funded Capital - Total Cash Collected
    ROUND(SUM(funded_amnt) - SUM(total_pymnt), 2)       AS net_economic_cash_loss,
    -- Pre-default principal recovery rate
    ROUND(SUM(total_rec_prncp) * 100.0 / SUM(funded_amnt), 2) AS pre_default_principal_recovery_pct,
    -- Net portfolio cash multiple on defaulted loans
    ROUND(SUM(total_pymnt) / SUM(funded_amnt), 4)       AS defaulted_cash_return_multiple
FROM fact_loans
WHERE loan_status = 'Charged Off';


-- ------------------------------------------------------------------------------
-- Query 6.2: Post-Default Recovery Rate and Loss Severity Analysis
-- Business Question:
--   How effective were post-charge-off collection efforts in recouping written-off
--   principal, and what is the realized loss severity?
-- Explanation:
--   Computes recovery rates using the defensible accounting denominator:
--   the Uncollected Principal Balance at Default (Funded Amount - Principal Repaid).
--   Also calculates loss severity (1 - total cash multiple).
-- ------------------------------------------------------------------------------
WITH default_aggregates AS (
    SELECT 
        SUM(funded_amnt)                                AS total_funded,
        SUM(total_rec_prncp)                            AS total_pre_default_prncp,
        SUM(funded_amnt) - SUM(total_rec_prncp)         AS uncollected_principal,
        SUM(recoveries)                                 AS total_gross_recoveries,
        SUM(collection_recovery_fee)                    AS total_fees,
        SUM(net_recoveries)                             AS total_net_recoveries,
        SUM(total_pymnt)                                AS total_cash
    FROM fact_loans
    WHERE loan_status = 'Charged Off'
)
SELECT 
    total_funded,
    uncollected_principal,
    total_gross_recoveries,
    total_fees,
    total_net_recoveries,
    -- Gross Recovery Rate = Gross Recoveries / Uncollected Principal Deficit
    ROUND(total_gross_recoveries * 100.0 / uncollected_principal, 2) AS gross_recovery_rate_pct,
    -- Net Recovery Rate = Net Recoveries / Uncollected Principal Deficit
    ROUND(total_net_recoveries * 100.0 / uncollected_principal, 2)   AS net_recovery_rate_pct,
    -- Fee Drag = Percentage of Gross Recoveries consumed by collection fees
    ROUND(total_fees * 100.0 / total_gross_recoveries, 2)            AS collection_fee_drag_pct,
    -- Realized Loss Severity = (1 - Total Cash Returned / Funded Capital)
    ROUND((1.0 - total_cash / total_funded) * 100.0, 2)              AS portfolio_loss_severity_pct
FROM default_aggregates;


-- ------------------------------------------------------------------------------
-- Query 6.3: Recovery Performance Across Credit Grades (A through G)
-- Business Question:
--   Does borrower credit quality affect post-default collection recovery rates,
--   or do prime borrowers yield higher salvage value after default?
-- Explanation:
--   Analyzes recovery economics across grades A to G among defaulted loans.
-- ------------------------------------------------------------------------------
SELECT 
    d.grade,
    COUNT(*)                                            AS defaulted_loans,
    SUM(f.funded_amnt)                                  AS gross_defaulted_capital,
    ROUND(SUM(f.funded_amnt) - SUM(f.total_rec_prncp), 2) AS uncollected_principal_deficit,
    SUM(f.recoveries)                                   AS gross_recoveries,
    SUM(f.net_recoveries)                               AS net_recoveries,
    -- Net recovery rate on uncollected principal
    ROUND(
        SUM(f.net_recoveries) * 100.0 / 
        NULLIF(SUM(f.funded_amnt) - SUM(f.total_rec_prncp), 0), 
        2
    )                                                   AS net_recovery_rate_pct,
    -- Net total cash return multiple on defaulted cohort
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
WHERE f.loan_status = 'Charged Off'
GROUP BY d.grade
ORDER BY d.grade ASC;


-- ------------------------------------------------------------------------------
-- Query 6.4: The 71 Zero-Installment Default Loans: Cash Flow & Recovery Audit
-- Business Question:
--   What are the actual financial outcomes of the 71 loans that recorded NULL
--   for last payment date? Did they truly default with zero total cash recovery?
-- Explanation:
--   Investigates the 71 loans with last_pymnt_date IS NULL. Demonstrates that while
--   scheduled pre-default principal and interest were zero, third-party recovery
--   cash flows were collected on 55 of the 71 loans.
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN total_pymnt = 0.00 THEN '1. Pure Zero Recovery ($0 Total Payment)'
        ELSE '2. Partial Recovery via Third-Party Collections'
    END                                                 AS recovery_category,
    COUNT(*)                                            AS loan_count,
    ROUND(COUNT(*) * 100.0 / 71.0, 2)                   AS share_of_71_pct,
    SUM(funded_amnt)                                    AS total_funded_capital,
    SUM(total_rec_prncp)                                AS pre_default_principal_collected,
    SUM(total_rec_int)                                  AS pre_default_interest_collected,
    SUM(recoveries)                                     AS post_default_recoveries,
    SUM(collection_recovery_fee)                        AS collection_fees_deducted,
    SUM(total_pymnt)                                    AS total_cash_collected,
    ROUND(AVG(total_pymnt), 2)                          AS avg_cash_collected,
    MAX(total_pymnt)                                    AS max_cash_collected
FROM fact_loans
WHERE last_pymnt_date IS NULL
GROUP BY recovery_category
ORDER BY recovery_category ASC;
