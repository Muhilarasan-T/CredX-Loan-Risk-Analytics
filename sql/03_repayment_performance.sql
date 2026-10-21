-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 03. Repayment Performance
-- File: sql/03_repayment_performance.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 3.1: Overall Portfolio Principal and Interest Collection Multiples
-- Business Question:
--   What percentage of the originally funded principal has been recovered,
--   how much interest has been harvested relative to principal, and what is the
--   total portfolio cash return multiple?
-- Explanation:
--   Computes macro-level capital recovery ratios across all 39,717 loans.
-- ------------------------------------------------------------------------------
SELECT 
    COUNT(*)                                            AS total_loans,
    SUM(funded_amnt)                                    AS total_funded_capital,
    SUM(total_rec_prncp)                                AS total_principal_collected,
    SUM(total_rec_int)                                  AS total_interest_collected,
    SUM(total_rec_late_fee)                             AS total_late_fees_collected,
    SUM(total_pymnt)                                    AS total_cash_received,
    ROUND(SUM(total_rec_prncp) * 100.0 / SUM(funded_amnt), 2) AS principal_collection_pct,
    ROUND(SUM(total_rec_int) * 100.0 / SUM(funded_amnt), 2)   AS interest_yield_on_funded_pct,
    ROUND(SUM(total_pymnt) / SUM(funded_amnt), 4)              AS total_cash_return_multiple
FROM fact_loans;


-- ------------------------------------------------------------------------------
-- Query 3.2: Detailed Repayment Economics: Fully Paid vs. Charged Off vs. Current
-- Business Question:
--   How do cash flows, principal write-downs, and realized yields differ between
--   successful borrowers, defaulted borrowers, and ongoing loans?
-- Explanation:
--   Compares average funded capital, average total payments, net principal loss
--   (unrecovered principal), and recovery ratios across all three loan outcomes.
-- ------------------------------------------------------------------------------
SELECT 
    loan_status,
    COUNT(*)                                            AS loan_count,
    ROUND(AVG(funded_amnt), 2)                          AS avg_funded_amount,
    ROUND(AVG(total_pymnt), 2)                          AS avg_total_payment,
    ROUND(AVG(total_rec_prncp), 2)                      AS avg_principal_repaid,
    ROUND(AVG(total_rec_int), 2)                        AS avg_interest_paid,
    SUM(funded_amnt)                                    AS total_funded_capital,
    SUM(total_rec_prncp)                                AS total_principal_repaid,
    -- Net principal deficit (unrecovered principal)
    ROUND(SUM(funded_amnt) - SUM(total_rec_prncp), 2)   AS unrecovered_principal,
    -- Realized principal recovery ratio
    ROUND(SUM(total_rec_prncp) * 100.0 / SUM(funded_amnt), 2) AS principal_repayment_rate_pct,
    -- Net total cash multiple per status
    ROUND(SUM(total_pymnt) / SUM(funded_amnt), 4)       AS status_cash_return_multiple
FROM fact_loans
GROUP BY loan_status
ORDER BY total_funded_capital DESC;


-- ------------------------------------------------------------------------------
-- Query 3.3: Repayment Efficiency and Default Risk by Loan Term (36 vs. 60 Months)
-- Business Question:
--   Does loan duration (36-month vs 60-month term) impact repayment efficiency,
--   interest yield collection, and credit risk?
-- Explanation:
--   Evaluates portfolio performance by loan term, calculating the terminal charge-off
--   rate, average interest rate, and total cash return multiple for each term.
-- ------------------------------------------------------------------------------
SELECT 
    d.term                                              AS loan_term,
    d.loan_term_months,
    COUNT(*)                                            AS total_loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS term_loan_share_pct,
    ROUND(AVG(d.int_rate), 2)                           AS avg_interest_rate_pct,
    ROUND(AVG(f.funded_amnt), 2)                        AS avg_funded_amount,
    SUM(f.funded_amnt)                                  AS total_funded_capital,
    SUM(f.total_pymnt)                                  AS total_payments_collected,
    ROUND(SUM(f.total_pymnt) / SUM(f.funded_amnt), 4)   AS cash_return_multiple,
    -- Terminal charge-off rate (excluding Current loans from denominator)
    SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    SUM(f.is_terminal_status)                           AS terminal_loans,
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
GROUP BY d.term, d.loan_term_months
ORDER BY d.loan_term_months ASC;


-- ------------------------------------------------------------------------------
-- Query 3.4: Active Portfolio Exposure & Outstanding Principal Breakdown
-- Business Question:
--   What is the outstanding principal balance and expected interest servicing
--   profile of active loans that are still in repayment?
-- Explanation:
--   Analyzes active Current loans to inspect unpaid principal balances (UPB)
--   for both the platform and individual retail investors.
-- ------------------------------------------------------------------------------
SELECT 
    f.loan_status,
    COUNT(*)                                            AS active_loan_count,
    SUM(f.funded_amnt)                                  AS original_funded_capital,
    SUM(f.total_rec_prncp)                              AS principal_already_collected,
    SUM(f.out_prncp)                                    AS total_outstanding_principal,
    SUM(f.out_prncp_inv)                                AS investor_outstanding_principal,
    ROUND(AVG(f.out_prncp), 2)                          AS avg_outstanding_principal,
    ROUND(AVG(f.last_pymnt_amnt), 2)                    AS avg_last_payment_amount,
    ROUND(AVG(d.installment), 2)                        AS avg_scheduled_monthly_installment,
    MIN(f.next_pymnt_date)                              AS earliest_next_payment_due,
    MAX(f.next_pymnt_date)                              AS latest_next_payment_due
FROM fact_loans f
JOIN dim_loan_details d ON f.loan_detail_key = d.loan_detail_key
WHERE f.loan_status = 'Current'
GROUP BY f.loan_status;
