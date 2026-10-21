# CredX — Analytical Limitations & Methodological Caveats

**Project:** CredX — Loan Risk & Repayment Analytics  
**Document Purpose:** Academic, Methodological & Enterprise Transparency  

---

## 1. Historical Dataset Context & Vintage Representativeness

* **Macroeconomic Cycle:** The dataset spans loan originations from June 2007 through December 2011. This timeframe directly coincides with the **2007–2009 Global Financial Crisis (Great Recession)** and subsequent early recovery. Consequently, macroeconomic stress, elevated unemployment, and liquidity contraction significantly influenced borrower default behavior during this era.
* **Underwriting Evolution:** Lending Club operated as an early-stage peer-to-peer (P2P) lending platform during this window. Many modern digital credit innovations (instant bank account verification via Plaid, alternative data, automated fraud signals, modern credit bureau scoring algorithms) were not present. A substantial portion of borrower income (over 40%) was "Not Verified."
* **External Validity:** Observed charge-off rates and recovery dynamics reflect this specific historical cohort and should not be treated as representative of contemporary consumer credit portfolios without recalibration.

---

## 2. Terminal Default Rate & Censoring of Active Loans

* **Censoring Semantics:** In the dataset, **1,140 loans (2.87%)** hold an active status of `'Current'`. Because these contracts had not yet reached contractual maturity at the time of data extract, their ultimate performance remains unobserved (right-censored).
* **Denominator Treatment:**  
  $$\text{Terminal Charge-off Rate} = \frac{\text{Charged Off Loans}}{\text{Fully Paid Loans} + \text{Charged Off Loans}} = \frac{5,627}{32,950 + 5,627} = 14.5862\% \approx 14.59\%$$
* If calculated naively against the total portfolio including active loans:
  $$\text{Nominal Loss Rate} = \frac{5,627}{39,717} = 14.1677\% \approx 14.17\%$$
* CredX explicitly documents and implements the **Terminal Charge-off Rate** using three-valued logic (`is_charged_off` is `NULL` for Current loans), avoiding artificial downward distortion from active contracts.

---

## 3. Cash Flow Timing: Snapshot Attribution vs. Transactional Ledgers

* **Absence of Payment Event Stream:** The underlying Lending Club dataset is a snapshot-level contract summary, not a normalized transactional ledger containing individual monthly payment records.
* **Last Payment Date Attribution:** In analytical charts depicting monthly repayment timelines (such as Power BI Page 3: Repayment & Recovery), each loan's cumulative cash inflow (`total_pymnt`) is attributed to its `last_pymnt_d`.
* **Analytical Impact:** This aggregates total payments to the date of the final payment event rather than smoothing cash inflows across the 36 or 60 monthly installment cycles. This is an accurate representation of the snapshot data structure, but should not be interpreted as an exact daily banking cash collection series.

---

## 4. Data Hygiene, Masking & Granularity Constraints

1. **Missing Payment Records (71 Loans):**  
   71 loans recorded zero scheduled payment entries (`last_pymnt_date IS NULL`). Forensic auditing revealed that 55 of these loans recorded post-charge-off recoveries (averaging $617.71). This indicates early-stage default prior to the establishment of regular servicing schedules, followed by secondary debt collection.
2. **Geographic Masking:**  
   Zip codes are truncated to 3 digits (e.g., `'941xx'`) to preserve borrower privacy under federal anonymization standards. This prevents granular municipal or census-tract demographic matching.
3. **High-Cardinality Unstructured Fields:**  
   Borrower job titles (`emp_title`) were self-reported freeform text entries containing over 28,000 distinct strings (misspellings, abbreviations, informal terms). While cleaned for database storage, occupational segmentation was intentionally limited to verified high-level categories rather than noisy free-text classifications.
4. **Rounding Precision Variance:**  
   Source raw payment records contained fractional cents with up to 6 decimal digits. Storing financial figures using industry-standard `DECIMAL(10,2)` currency precision resulted in an accumulated rounding variance of **+$0.48** across **$482.7 million** in portfolio transactions (a relative variance of $0.0000001\%$).

---

## 5. Analytical Scope & Claim Boundaries

* **Diagnostic & Descriptive Focus:** CredX is intentionally scoped as a descriptive and diagnostic business intelligence platform, dimensional data warehouse, and SQL analytical engine.
* **No Predictive Causal Claims:** Observed correlations (e.g., small business loans exhibiting higher charge-offs, or mortgage holders having higher incomes) reflect historical associations, not definitive causal mechanisms.
* **No Autonomous Default Prevention:** CredX provides transparency, risk monitoring, and executive visibility; it does not claim to autonomously eliminate defaults or guarantee financial returns.
