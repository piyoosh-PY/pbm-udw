# Class 4: Gold, dimensional model + metrics (2026-10-18)

Result: `dbt build` -> PASS=76 WARN=2 ERROR=0 TOTAL=78 (the 2 warns are the expected bronze duplicates and orphan members)

## Part 0. Business primer: the money on one fill (real rows)

| | Atorvastatin (generic) | Eliquis-like (brand) |
|---|---|---|
| AWP (list price) | $13.50 | $285.00 |
| Ingredient cost paid (contract: AWP - x%) | $10.80 | $236.55 |
| + Dispensing fee | $1.50 | $1.00 |
| = Gross cost | $12.30 | $237.55 |
| Member pays (copay) | $10.00 | $40.00 |
| Plan pays | $2.30 | $197.55 |

- Gross cost = patient pay + plan paid (holds on all 24,060 fills; it's a test now).
- Generics: 76% of fills, ~2% of plan spend. Brands and specialty drive cost.
- Players: client (employer/plan) pays PBM; PBM reimburses pharmacy; member pays copay; manufacturer pays rebates to PBM (passed mostly to client).
- Rebate = manufacturer money for brand placement, invoiced quarterly by NDC x units. Rebill (B3) = corrected claim. Different things.

| Metric | Formula | Benchmark (real commercial) | Ours (Sep, synthetic) |
|---|---|---|---|
| Member month | 1 member covered 1 month | | 2,654 |
| PMPM | plan paid / member months | ~$100-150 | $2,404.70 (attributed) |
| GDR | generic fills / fills with known drug | 85-90% | 77% |
| Specialty share | specialty plan paid / plan paid | ~50% | 73% |
| Scripts PMPM | adjusted (30-day) scripts / MM | ~1 | 12.4 |

Synthetic utilization is ~10x real. In a real job a number this far from benchmark = stop and investigate before publishing.

## Part 1. Architecture concepts

- **Fact vs dimension:** fact = event you measure (verbs, numbers, tall). Dimension = context (nouns, text you group by, wide and small).
- **Grain:** one sentence for what one row means, declared before SQL. `fct_pharmacy_claim` = one row per final paid fill.
- **Fan-out:** joining a fact to a dimension with more than one row per key multiplies rows. Proof on our data: joining fills to dim_member on member_key only = 24,580 rows and $7,105,963 vs correct 24,060 and $6,986,722 (+$119,241). Guard: `unique` test on the fact grain.
- **Star vs snowflake vs OBT:** star for the core (simple joins, reusable dims); OBT-style marts on top for consumers; snowflake rarely worth it in cloud warehouses.
- **Surrogate keys:** md5 of natural key (+ effective_from for SCD2). One natural key, many versions. Special rows `-1` unknown member (orphan), `-2` known member with no coverage on DOS; never NULL FKs.
- **SCD1 vs SCD2 per column:** corrections (birth date) overwrite history (SCD1); real events (plan change) get a new version (SCD2).
- **Role-playing dimension:** dim_provider joined twice (pharmacy, prescriber).
- **Conformed dimension:** dim_member feeds both the claims numerator and member-month denominator, so they describe the same population.
- **Degenerate dimension:** fill_key, rx_number live on the fact with no dim table.
- **HIPAA minimum necessary:** names stay in silver; gold has zip3 and no names.

## What I built

| Model | Layer | Grain | Rows |
|---|---|---|---|
| `int_rebates` | silver | quarter x NDC (latest file wins) | 12 |
| `dim_drug` | gold | NDC + Unknown | 15 |
| `dim_provider` | gold | NPI + Unknown | 373 |
| `dim_member` | gold | member x coverage version (SCD2, business time) + -1/-2 | 2,844 |
| `fct_pharmacy_claim` | gold | final paid fill | 24,060 |
| `fct_member_month` | gold | member x month (covered on the 15th) | per month ~2.6K |
| `mart_client_month_metrics` | gold | client x plan x month | |
| `rpt_rebate_reconciliation` | gold | quarter x NDC | 12 |

Tests added: unique/not_null on every surrogate key and grain, relationships fact -> dims, plus singular tests
`assert_gold_fact_ties_to_silver_paid_fills`, `assert_mart_ties_to_fact`, `assert_covered_fills_fall_inside_member_version`,
`assert_gross_cost_equals_patient_plus_plan` (warn).

## Results

**Where every paid dollar landed (point-in-time join):**
| Bucket | member_sk | Fills | Plan paid |
|---|---|---|---|
| Covered | real version | 23,332 | $6,727,311.98 |
| Orphan (no eligibility yet) | -1 | 100 | $26,953.73 |
| No coverage on DOS | -2 | 628 | $232,456.45 |
| ...of which filled after termination | | 525 | $195,971.97 (recovery candidates) |
| ...invalid span / never effective / before start | | 73 / 21 / 9 | $27,237 / $4,128 / $5,119 |

**Member D (plan change Sep 15):** Sep 13 fill $483.90 -> PPO_RX_A version; Sep 17 fill -> PPO_RX_B version.

**Member-month counting rules (comparison):**
| Rule | Aug | Sep | Oct |
|---|---|---|---|
| any day | 2,614 | 2,654 | 2,628 |
| 1st of month | 2,614 | 2,654 | 2,598 |
| 15th (chosen, `var('member_month_counting_day')`) | 2,614 | 2,654 | 2,628 |
| last day | 2,614 | 2,624 | 2,628 |
| fractional | 2,614 | 2,644.5 | 2,627 |

**Incomplete-month trap:** PMPM Aug $64.68, Sep $2,493.58, Oct $75.99. Aug and Oct have 1 day of claims against a full month of members -> `is_complete_month` flag.

**Population trap:** Sep PMPM with unattributed spend in the numerator = $2,493.58; attributed only = $2,404.70.

**Average-of-ratios trap:** plan A $10K/100 MM ($100), plan B $90K/300 MM ($300). Average $200 is wrong; sum/sum $250 is right. Store additive pieces next to ratios.

**Rebates Q3:** under-invoiced Jardiance-like +$274K, Eliquis-like +$152K, Brandastatin +$63K (=$490K, conclusive as a lower bound).
Over-invoiced specialty pens: inconclusive, because the warehouse holds only 33.7% of Q3 claims. Q4: quarter still open, so wait (and an invoice before quarter close is itself a source issue).

## Lessons from the lab
1. **Define special buckets precisely.** First version showed 194 orphans; "known member" was defined as "has a valid span", so members with invalid/never-effective spans were mislabeled. Fix: known = any eligibility record. Result: 100 orphans, 628 no-coverage.
2. **Partial data is asymmetric.** Missing claims can only make dispensed units look smaller: under-billing is provable (lower bound), over-billing is not.
3. **Member-month rule is a contract definition.** Parameterize it, document it.
4. **Benchmark every headline metric** before publishing.

## Interview answers (30 seconds each)
- **"Walk me through a dimensional model you built."** "For pharmacy claims I declared the grain first: one row per final paid fill, after reversal netting. Dimensions for member, drug and provider with surrogate keys. The member dimension is SCD2 on coverage dates, and the fact joins it point-in-time on date of service, so a retro plan change never rewrites history. Unmatched rows point to special unknown or no-coverage rows instead of NULLs, and tests prove gold ties to silver to the cent."
- **"How do you calculate PMPM, and what goes wrong?"** "Plan paid over member months, where both come from the same conformed member dimension. Three traps: incomplete months, where a partial month of claims sits against a full month of members, so I flag complete months; populations that don't match, where unattributed spend inflates the numerator; and averaging ratios across plans instead of dividing sums."
- **"What's GDR and why does a client care?"** "Generic fills over all fills with a known drug. Generics are a fraction of brand cost, so each point of GDR is real savings. I exclude unknown NDCs from the denominator instead of calling them brand."
- **"How would you reconcile rebates?"** "Units dispensed from paid claims times the contract rate, against invoiced units, per quarter and NDC with a full outer join. Before acting I check the quarter is closed and that we hold the full quarter's claims. Under-billing with partial data is still provable as a lower bound; over-billing isn't, so I'd flag it rather than dispute with the manufacturer."
- **"Business impact story."** "Point-in-time eligibility surfaced about $196K of claims paid after retro-terminations: a recovery list the client can act on. That only shows up if the member dimension is effective-dated."
