# Class 2: Silver, cleaning dirty data (2026-10-17)

Result: `dbt build` -> PASS=32 WARN=2 ERROR=0 TOTAL=34
- WARN 150: unique transaction_id in bronze (expected; duplicates are removed in silver)
- WARN 40: fills -> eligibility relationship (orphan members, soft rule by design)

## Theory

**Six data-quality dimensions:** completeness, validity, accuracy, consistency, uniqueness, timeliness.

**Four kinds of "duplicate" (each needs a different fix):**
| Kind | Example | Fix |
|---|---|---|
| Exact duplicate | same transaction_id sent twice | `row_number() ... = 1`, any deterministic order |
| Latest wins | 834 add (021) then change (001) for one member | order by load time desc, code as tie-breaker |
| Event lifecycle | B1 paid, B2 reversed, B3 rebilled for one fill | net by business key (fill_key), latest status wins |
| Survivorship | same NPI with two name spellings | rule picks the golden value (longest name, then alpha) |

**Deterministic ordering:** every `row_number()` needs a unique last tie-breaker (transaction_id). Without one, ties pick a random row on each run and numbers drift between runs. Business precedence (B3 > B2 > B1 when timestamps tie) is stronger than an arbitrary column.

**Terms:** B3 = *rebill* (corrected resubmission). A *rebate* is manufacturer money paid to the PBM. Never mix them up.

**Quarantine vs flag vs repair:**
| Action | When | Our rules |
|---|---|---|
| Repair | format problem, meaning is certain | `$1,204.50` -> 1204.50; NDC 10 -> 11; names proper-cased; MM/DD/YYYY dates |
| Quarantine | won't fix itself; would corrupt metrics | future date of service, days supply outside 1-365, unparseable amount/date/NDC |
| Keep + flag | may resolve later, or still a real paid claim | orphan member (late eligibility), NDC not in drug file, invalid prescriber NPI |
Quarantine is not "drop": rows are kept with reasons and reprocessed once fixed.

**Reconciliation identity:** bronze rows = typed rows + duplicates removed; typed rows = valid + quarantined. Nothing disappears silently.

## What I built
- `macros/cleaning.sql`: normalize_ndc, is_valid_npi (Luhn over '80840'||npi), clean_amount, parse_date_multi. Checked with `analyses/macro_check.sql`.
- `int_drugs`, `int_providers` (survivorship), `int_eligibility` (member_key = cardholder + person code, latest wins)
- `int_pharmacy_claims__typed`: dedup, typing, repairs, hard and soft dq_ flags, `quarantine_reasons` list
- `int_pharmacy_claims__quarantine`: hard-rule failures with reasons
- `int_pharmacy_fills`: reversal netting, one row per final paid fill
- Tests: generic tests per model, plus `assert_claims_reconcile_bronze_to_silver` and `assert_silver_handles_every_claims_defect` (every injected defect has its expected effect; the manifest acts as a golden dataset)

## Results (Sep 30 load)
| Metric | Value |
|---|---|
| Typed transactions | 21,394 (150 exact dups removed) |
| Quarantined | 35 (25 days supply, 10 future DOS) |
| Final fills | 19,059 (18,665 B1 + 394 B3 rebills) |
| Reversed, never rebilled | 606 (absent from fills) |
| Plan paid, net | B1 $5,527,458.80 + B3 $76,237.61 |
| Flags kept | 40 orphan members, 35 invalid prescriber NPIs, 60 NDCs not in reference |
| NDCs normalized 10 -> 11 | 400 |
| Members | 2,693; 11 coverage spans end before start |

## Lessons from the lab
1. **A green run can hide skipped tests.** A typo (`int_pharmacy_claims__types`) attached 3 tests to a model that doesn't exist. dbt only warned: "Did not find matching node for patch", and TOTAL fell from 34 to 31. Guard: watch the node count; in CI, make `NoNodeForYamlKey` an error with `--warn-error-options`.
2. **DuckDB:** `unnest` can't share a SELECT with `group by`; unnest in a subquery first.
3. **The 11 vs 8 coverage spans.** 8 were injected (end 15 days before start = data-entry error). 3 more are start 2026-09-01, end 2026-08-31: a **retro-termination / never-effective** enrollment (the employer canceled before coverage began; two are the same household, RW100241-01 and -02). That's a real business event, not bad data. A rule like `end < start` needs business context: split the flag into `is_never_effective` (end = start - 1) vs `dq_invalid_span`, and confirm with the eligibility/ops team. Follow-up: these members have claims attached, so check whether any fill's date of service falls outside a valid span (claims paid without coverage = recovery opportunity).

## Interview answers (30 seconds each)
- **"How do you handle reversals?"** Net at the fill grain: key = pharmacy NPI + Rx number + fill number + date of service. Latest transaction wins, with a unique tie-breaker. Latest B1/B3 paid = fill counted; latest B2 = gone. Never sum raw transactions; B2 amounts come in positive.
- **"Quarantine or drop?"** Neither by default. Repair what's certain, quarantine what can't self-correct (with reasons, reprocessable), and keep-and-flag what may resolve, like late eligibility. Prove it with a reconciliation identity test.
- **"How do you know your cleaning works?"** A golden dataset of known defects with expected outcomes, rerun on every change: the same idea as evals for an LLM agent.
- **"A rule fires more than expected; what do you do?"** Look at the rows before fixing the rule. Here, 3 of 11 "bad" spans were legitimate retro-terms. Rules encode business meaning, so confirm with the business owner.
