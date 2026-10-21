-- ==============================================================================
-- CredX — Loan Risk & Repayment Analytics
-- Phase 5: Business Analytics Queries — 08. Advanced SQL Analytics
-- File: sql/08_advanced_analytics.sql
-- Target DBMS: MySQL 8.0+
-- Database: credx
-- ==============================================================================

USE credx;

-- ------------------------------------------------------------------------------
-- Query 8.1: Window Function: Purpose Risk Ranking Within Each Credit Grade
-- Business Question:
--   Within each credit grade (A to G), which loan purposes carry the highest
--   default risk, and how do they rank relative to one another?
-- Explanation:
--   Uses DENSE_RANK() window function partitioned by credit grade to rank
--   loan purposes by terminal charge-off rate. Filters to purposes with $\ge 20$
--   loans for statistical reliability.
-- ------------------------------------------------------------------------------
WITH grade_purpose_metrics AS (
    SELECT 
        ld.grade,
        ld.purpose,
        COUNT(*)                                        AS total_loans,
        SUM(f.is_terminal_status)                       AS terminal_loans,
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
        ROUND(
            SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
            NULLIF(SUM(f.is_terminal_status), 0), 
            2
        )                                               AS terminal_charge_off_rate_pct,
        ROUND(AVG(ld.int_rate), 2)                      AS avg_interest_rate,
        SUM(f.funded_amnt)                              AS total_funded_capital
    FROM fact_loans f
    JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
    GROUP BY ld.grade, ld.purpose
    HAVING COUNT(*) >= 20
)
SELECT 
    grade,
    DENSE_RANK() OVER (
        PARTITION BY grade 
        ORDER BY terminal_charge_off_rate_pct DESC
    )                                                   AS risk_rank_within_grade,
    purpose,
    total_loans,
    terminal_loans,
    charged_off_loans,
    terminal_charge_off_rate_pct,
    avg_interest_rate,
    total_funded_capital
FROM grade_purpose_metrics
ORDER BY grade ASC, risk_rank_within_grade ASC;


-- ------------------------------------------------------------------------------
-- Query 8.2: Window Function: Month-over-Month Capital Deployment & Trailing Growth
-- Business Question:
--   What was the monthly capital origination pace, Month-over-Month (MoM) growth,
--   and running cumulative capital deployed over the operating timeline?
-- Explanation:
--   Uses LAG() and SUM() OVER() window functions to calculate MoM dollar growth,
--   MoM percentage growth, and cumulative running balance across months.
-- ------------------------------------------------------------------------------
WITH monthly_originations AS (
    SELECT 
        d.`year_month`                                  AS origination_period,
        f.issue_date,
        COUNT(*)                                        AS monthly_loans,
        SUM(f.funded_amnt)                              AS monthly_funded_amount
    FROM fact_loans f
    JOIN dim_dates d ON f.issue_date = d.calendar_date
    GROUP BY d.`year_month`, f.issue_date
)
SELECT 
    origination_period,
    monthly_loans,
    monthly_funded_amount,
    LAG(monthly_funded_amount, 1) OVER (ORDER BY issue_date) AS prev_month_funded,
    ROUND(
        (monthly_funded_amount - LAG(monthly_funded_amount, 1) OVER (ORDER BY issue_date)) * 100.0 / 
        NULLIF(LAG(monthly_funded_amount, 1) OVER (ORDER BY issue_date), 0), 
        2
    )                                                   AS mom_capital_growth_pct,
    -- Running cumulative total of capital funded
    SUM(monthly_funded_amount) OVER (
        ORDER BY issue_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS running_cumulative_funded
FROM monthly_originations
ORDER BY issue_date ASC;


-- ------------------------------------------------------------------------------
-- Query 8.3: Conditional Aggregation: Cross-Vintage Term Default Matrix (Pivot)
-- Business Question:
--   How did default rates across loan terms (36 vs 60 months) evolve across
--   origination years (2007 through 2011)?
-- Explanation:
--   Constructs an analytical cross-tabulation (matrix pivot) using conditional
--   aggregation (CASE WHEN) to compare 36-month vs 60-month default rates by vintage.
-- ------------------------------------------------------------------------------
SELECT 
    d.`year`                                            AS vintage_year,
    COUNT(*)                                            AS total_vintage_loans,
    -- 36-Month Term Metrics
    SUM(CASE WHEN ld.loan_term_months = 36 THEN 1 ELSE 0 END) AS loans_36m,
    ROUND(
        SUM(CASE WHEN ld.loan_term_months = 36 AND f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(CASE WHEN ld.loan_term_months = 36 AND f.is_terminal_status = 1 THEN 1 ELSE 0 END), 0), 
        2
    )                                                   AS charge_off_rate_36m_pct,
    -- 60-Month Term Metrics
    SUM(CASE WHEN ld.loan_term_months = 60 THEN 1 ELSE 0 END) AS loans_60m,
    ROUND(
        SUM(CASE WHEN ld.loan_term_months = 60 AND f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(CASE WHEN ld.loan_term_months = 60 AND f.is_terminal_status = 1 THEN 1 ELSE 0 END), 0), 
        2
    )                                                   AS charge_off_rate_60m_pct,
    -- Overall Vintage Terminal Default Rate
    ROUND(
        SUM(CASE WHEN f.loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(f.is_terminal_status), 0), 
        2
    )                                                   AS overall_vintage_charge_off_pct
FROM fact_loans f
JOIN dim_dates d ON f.issue_date = d.calendar_date
JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
GROUP BY d.`year`
ORDER BY d.`year` ASC;


-- ------------------------------------------------------------------------------
-- Query 8.4: NTILE(10) Decile Analysis of Borrower Leverage (Loan-to-Income)
-- Business Question:
--   When dividing all borrowers into 10 equal deciles of loan-to-income leverage,
--   how does default risk escalate across each decile?
-- Explanation:
--   Applies NTILE(10) window function across the 39,717 loans ordered by
--   loan_to_income_ratio, demonstrating the statistical monotonicity of leverage risk.
-- ------------------------------------------------------------------------------
WITH ranked_loans AS (
    SELECT 
        f.loan_id,
        f.loan_to_income_ratio,
        f.funded_amnt,
        f.loan_status,
        f.is_terminal_status,
        b.annual_inc,
        NTILE(10) OVER (ORDER BY f.loan_to_income_ratio ASC) AS leverage_decile
    FROM fact_loans f
    JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
)
SELECT 
    leverage_decile,
    COUNT(*)                                            AS decile_loan_count,
    ROUND(MIN(loan_to_income_ratio), 4)                 AS min_loan_to_income,
    ROUND(MAX(loan_to_income_ratio), 4)                 AS max_loan_to_income,
    ROUND(AVG(loan_to_income_ratio), 4)                 AS avg_loan_to_income,
    ROUND(AVG(annual_inc), 2)                           AS avg_borrower_income,
    ROUND(AVG(funded_amnt), 2)                          AS avg_loan_size,
    SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    -- Decile terminal charge-off rate
    ROUND(
        SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(is_terminal_status), 0), 
        2
    )                                                   AS decile_charge_off_rate_pct
FROM ranked_loans
GROUP BY leverage_decile
ORDER BY leverage_decile ASC;


-- ------------------------------------------------------------------------------
-- Query 8.5: Multi-Factor Composite Risk Pipeline (CTE Layering)
-- Business Question:
--   When combining multiple risk indicators (high leverage, high interest rate,
--   long term, past delinquency), what fraction of the portfolio falls into
--   the severe risk tier, and what is their empirical default rate?
-- Explanation:
--   Constructs a modular multi-tier CTE scoring pipeline classifying loans into
--   'Prime / Low Risk', 'Moderate Risk', 'Elevated Risk', and 'Severe Risk'.
-- ------------------------------------------------------------------------------
WITH loan_risk_factors AS (
    SELECT 
        f.loan_id,
        f.funded_amnt,
        f.total_pymnt,
        f.loan_status,
        f.is_terminal_status,
        -- Score factors
        (CASE WHEN ld.loan_term_months = 60 THEN 1 ELSE 0 END) +
        (CASE WHEN ld.int_rate >= 15.00 THEN 1 ELSE 0 END) +
        (CASE WHEN f.loan_to_income_ratio >= 0.25 THEN 1 ELSE 0 END) +
        (CASE WHEN b.dti >= 20.00 THEN 1 ELSE 0 END) +
        (CASE WHEN b.delinq_2yrs > 0 THEN 1 ELSE 0 END) +
        (CASE WHEN b.pub_rec > 0 THEN 1 ELSE 0 END) AS risk_score
    FROM fact_loans f
    JOIN dim_loan_details ld ON f.loan_detail_key = ld.loan_detail_key
    JOIN dim_borrowers b ON f.borrower_key = b.borrower_key
),
segmented_risk AS (
    SELECT 
        loan_id,
        funded_amnt,
        total_pymnt,
        loan_status,
        is_terminal_status,
        risk_score,
        CASE 
            WHEN risk_score = 0 THEN 'Tier 1: Prime / Low Risk (0 Flags)'
            WHEN risk_score IN (1, 2) THEN 'Tier 2: Moderate Risk (1-2 Flags)'
            WHEN risk_score IN (3, 4) THEN 'Tier 3: Elevated Risk (3-4 Flags)'
            ELSE 'Tier 4: Severe High Risk (5+ Flags)'
        END AS composite_risk_tier
    FROM loan_risk_factors
)
SELECT 
    composite_risk_tier,
    COUNT(*)                                            AS total_loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS portfolio_share_pct,
    SUM(funded_amnt)                                    AS total_funded_capital,
    SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) AS charged_off_loans,
    ROUND(
        SUM(CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END) * 100.0 / 
        NULLIF(SUM(is_terminal_status), 0), 
        2
    )                                                   AS terminal_charge_off_rate_pct,
    ROUND(SUM(total_pymnt) / SUM(funded_amnt), 4)       AS cash_return_multiple
FROM segmented_risk
GROUP BY composite_risk_tier
ORDER BY composite_risk_tier ASC;
