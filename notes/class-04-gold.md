# Class 4: Gold layer, dimensional model + metrics (2026-10-18)

**Final state:** `dbt build` -> PASS=77 WARN=2 ERROR=0 TOTAL=79 (52 data tests).
The 2 warns are expected: 450 duplicate transaction_id values in bronze, 100 orphan members (soft rule).

**What gold answers:** silver gave clean data; gold answers business questions.
"What did client CL001 spend per member last month?" "Are we filling enough generics?" "Did we bill manufacturers the right rebate?"

**Files built in this class**
| Layer | File | Grain |
|---|---|---|
| silver | `models/silver/int_providers.sql` (typo fix `presciber` -> `prescriber`) | 1 per NPI |
| silver | `models/silver/int_rebates.sql` | quarter x NDC (latest file wins) |
| gold | `models/gold/dim_drug.sql` | 1 per NDC + `-1` Unknown |
| gold | `models/gold/dim_provider.sql` | 1 per NPI + `-1` Unknown (role-playing) |
| gold | `models/gold/dim_member.sql` | 1 per member coverage version (SCD2) + `-1` / `-2` |
| gold | `models/gold/fct_pharmacy_claim.sql` | 1 per final paid fill |
| gold | `models/gold/fct_member_month.sql` | 1 per member per month (covered on the 15th) |
| gold | `models/gold/mart_client_month_metrics.sql` | client x plan x service month |
| gold | `models/gold/rpt_rebate_reconciliation.sql` | rebate quarter x NDC |
| tests | `models/gold/_gold_models.yml` + 5 singular tests in `tests/` | |

---

## Part 0. Business primer: the money on one prescription (real rows)

| | Atorvastatin (generic) | Eliquis-like (brand) |
|---|---|---|
| AWP (list "sticker" price) | $13.50 | $285.00 |
| Ingredient cost paid (contract: AWP - x%) | $10.80 (AWP - 20%) | $236.55 (AWP - 17%) |
| + Dispensing fee (pharmacist labor) | $1.50 | $1.00 |
| = **Gross cost** | **$12.30** | **$237.55** |
| Member pays (copay) | $10.00 | $40.00 |
| Plan pays (employer via PBM) | $2.30 | $197.55 |

- **Gross cost = patient pay + plan paid.** Holds on all 24,060 paid fills (now a warn-level test).
- Generics: 76% of fills, ~2% of plan spend. **Brands and specialty drive plan cost.**
- AWP is a sticker price nobody pays; contracts are "AWP minus X%", so AWP lives on the drug dimension.

**Who pays whom**
```
CLIENT (employer/plan: CL001..CL003) --premiums + claims--> PBM --reimburses ingredient + fee--> PHARMACY <--copay-- MEMBER
DRUG MANUFACTURER --rebates (quarterly, by NDC x units)--> PBM --rebate share--> CLIENT
```
- **Client** = employer or health plan that hires the PBM. Every report is cut by client.
- **Rebate** = manufacturer money for preferred formulary placement of a brand. **Rebill (B3)** = corrected claim. Different things.

**The metrics**
| Term | Plain meaning | Formula | Real-world benchmark (commercial) | Ours (Sep, synthetic) |
|---|---|---|---|---|
| Member month (MM) | 1 member covered for 1 month | count of (member, month) | | 2,654 |
| PMPM | cost per member per month | plan paid / member months | ~$100-150 | $2,404.70 (attributed) |
| GDR | share of fills that are generic | generic fills / fills with a known drug | 85-90% | 77% |
| Specialty share | share of spend on specialty | specialty plan paid / plan paid | ~50% | 73% |
| Adjusted scripts PMPM | 30-day-equivalent scripts per member month | adjusted scripts / MM | ~1 | 12.4 |
| Member cost share | share of gross cost the member pays | patient paid / gross cost | | ~6% |
| Rebate reconciliation | did we invoice every dispensed unit? | dispensed units vs invoiced units | | +$490K under-invoiced (Q3, lower bound) |

Why PMPM and not total spend: Client A $1M / 10,000 members = $100 PMPM; Client B $500K / 2,000 = $250 PMPM. B is the expensive one.
Our synthetic utilization is ~10x real; at work a number that far off benchmark = stop and investigate before publishing.

## Part 1. Architecture concepts (Kimball)

| Concept | One-line meaning | In our project |
|---|---|---|
| Fact vs dimension | fact = event you measure (verbs, numbers, tall); dimension = context (nouns, text, wide, small) | fct_pharmacy_claim vs dim_member/drug/provider |
| **Grain** | one sentence for what ONE row means, declared before SQL | fact = one row per final paid fill |
| Fan-out | joining to a table with >1 row per key multiplies rows | naive member join: +520 rows, +$119K |
| Star / snowflake / OBT | star = dims one join away; snowflake = dims normalized further; OBT = one wide table | star core + OBT-style mart on top |
| Surrogate key | warehouse-owned key, md5 of natural key (+ effective_from for SCD2) | drug_sk, provider_sk, member_sk |
| Special dimension rows | never NULL foreign keys; say WHY there is no match | `-1` unknown, `-2` no coverage on DOS |
| SCD1 vs SCD2 per column | correction -> overwrite (SCD1); real event -> new version (SCD2) | birth date SCD1, plan SCD2 |
| Role-playing dimension | one dim joined several times in different roles | dim_provider as pharmacy and prescriber |
| Conformed dimension | built once, shared by every fact | dim_member feeds claims numerator and member-month denominator |
| Degenerate dimension | an ID on the fact with no dim table | fill_key, rx_number |
| Additive measure | safe to sum across any dimension | plan paid, member_month = 1 |
| HIPAA minimum necessary | each layer exposes only what its users need | no names in gold, zip3 only |

---

## Part 2. Step-by-step learning

### Step 0. Reset + setup
- Removed the pre-built gold files so every model was typed by hand; dropped leftover `main_gold` tables.
- Claude dry-ran each step on a copy first so the expected outputs below were known in advance.

### Step 1. `dim_drug` and `dim_provider`
**Goal:** surrogate keys, business labels, and an Unknown row so unmatched fills never vanish.
- `md5(ndc11) as drug_sk`: deterministic, same key every run and every environment (auto-increment IDs change on full refresh and break facts).
- `case multi_source_code`: Y = generic, N = single-source brand, O = brand with generic available, M = multi-source brand (our biosimilar).
- `is_rebate_eligible = multi_source_code in ('N','O')`.
- `union all` adds the `-1` row; columns match **by position**, types must line up. `union all` (not `union`) keeps every row and skips a dedup sort.
- dim_provider is a **role-playing dimension** (pharmacies and prescribers share NPIs).
- Fixed silver typo `presciber`: with it, every prescriber join would silently fall to Unknown.

**Results:** PASS=5. dim_drug 15 rows (generic 7, single-source brand 5, multi-source brand 1, brand-generic-available 1, unknown 1). dim_provider 373 (prescriber 312, pharmacy 60, unknown 1).

**Check question:** Why is the Unknown drug `false` for is_rebate_eligible but `null` for is_generic?
- **My answer:** false because we must not bill a manufacturer for a drug not under contract; null because we can't classify an unknown drug, which keeps it separate and allows later logic.
- **Feedback:** correct core idea: **false = a business decision we are sure of; null = an unknown fact.**
  Correction: null does not change *spend* (the 180 fills still count in plan paid and PMPM). It protects *classification metrics* like GDR: `false` would count them as brand and push GDR down.
  SQL detail: `where not is_generic` also drops NULLs (three-valued logic: `not null` is null). That's why the GDR denominator is `is_generic is not null`.

### Step 2. `dim_member` (SCD2 member dimension)
**Goal:** one row per member per coverage version, so a fill keeps the plan that was true on its date of service.
- Two CTEs, two history rules: `spans` (client/group/plan/effective dates, **SCD2**) and `demographics` (birth date, gender, zip, relationship, **SCD1** current values).
  Rule: *"Was the old value ever true?"* Yes -> SCD2. No, it was a mistake -> SCD1.
- `member_sk = md5(member_key || '|' || effective_from)`: effective_from makes each version unique; the `'|'` separator prevents collisions ('AB'+'1-2' vs 'A'+'B1-2').
- Relationship codes (834): 18 = subscriber, 01 = spouse, 19 = child.
- PHI: no names, zip3 only (HIPAA minimum necessary).
- `left join demographics`, not inner, so a missing demographic row can't drop coverage.
- `-1` / `-2` rows with 1900-01-01 .. 9999-12-31 so date filters keep them.

**Results:** PASS=9 (3 models + 6 tests). 2,844 rows = 2,762 members + 80 extra versions + 2 special rows.
| member_sk | member | plan | effective_from -> to |
|---|---|---|---|
| b173e016 | D RW101530-01 | PPO_RX_A | Jan 1 -> Sep 14 |
| 3426c6e5 | D RW101530-01 | PPO_RX_B | Sep 15 -> 9999-12-31 |
| f673cd87 | E RW101978-01 | PPO_RX_A | Jan 1 -> Sep 19 |
| 1261b363 | E RW101978-01 | PPO_RX_A | Sep 20 -> Sep 20 |
Member E's one-day v2 with the same plan: the termination changed `coverage_end_date`, a tracked `check_col`. **SCD2 versions on ANY tracked column, not just plan.**

**Experiment (break it):** key changed to `md5(member_key)`.
- Observation: unique test on member_sk failed because effective dates were not in the key, so members with 2 coverage spans got the same key twice.
- Number: **FAIL 80** (80 members with a second version; dbt's unique test counts duplicated *values*, not extra rows).

### Step 3. `fct_pharmacy_claim` (the fact)
**Goal:** paid fills only, surrogate keys instead of natural keys, the right member version, and never lose a row.
- CTEs: `fills` (paid only = the grain), `member_versions` (dim without special rows), `known_members` (anyone with ANY eligibility record, from `int_eligibility`).
- **Point-in-time join:** `on mv.member_key = f.member_key and f.date_of_service between mv.effective_from and mv.effective_to`.
  Safe only because Class 3 proved spans never overlap.
- `case` order matters: matched version -> `-2` if known -> `-1`. A case stops at the first true branch.
- `coalesce(x, '-1')` for drug and providers.
- **Role filter goes in `on`, not `where`:** a filter on the right table of a left join placed in `where` silently turns it into an inner join.
- Columns: FKs, degenerate dims (fill_key, rx_number), natural keys for tracing, additive measures, flags.
- `adjusted_rx_count = greatest(1, round(days_supply/30))`: a 90-day fill = 3 scripts, a 7-day fill = 1.
- `is_covered_on_dos` (today's truth from the dim) vs `dq_orphan_member` (silver's flag at processing time). Trust the fact's flag.

**Results:** PASS=9 (1 model + 8 tests).
| Bucket | member_sk | Fills | Plan paid | Meaning |
|---|---|---|---|---|
| covered | real version | 23,332 | $6,727,311.98 | normal |
| no coverage on DOS | -2 | 628 | $232,456.45 | recovery / audit dollars |
| orphan | -1 | 100 | $26,953.73 | eligibility not received; chase the 834 |
| **total** | | **24,060** | **$6,986,722.16** | = silver paid total |
Breakdown of -2: filled after termination 525 ($195,971.97), invalid span 73 ($27,237.18), never effective 21 ($4,128.30), before coverage start 9 ($5,119.00).
Member D: Sep 6/10/13 -> PPO_RX_A; Sep 17/24/28 -> PPO_RX_B. Unknown drug 180, unknown prescriber 105, unknown pharmacy 0.

**Experiment 1: fan-out (join on member_key only)**
| | My prediction | Actual |
|---|---|---|
| rows | fewer than 24,060 | **24,580 (+520)** |
| plan paid | ~$233K less | **$7,105,963.01 (+$119,241)** |
Both effects happen at once: inner join drops members not in dim_member (-194 fills, -$58,319) AND the 80 multi-version members duplicate (+714 fills, +$177,560). Duplicates win. They partly cancel, so a quick total check can look "roughly fine" while numbers are wrong in both directions. Only `unique(fill_key)` catches it directly.

**Experiment 2: bucket definition bug (`known_members` from `member_versions`)**
| | My prediction | Actual |
|---|---|---|
| orphan -1 | grows | 100 -> **194** ✅ |
| no coverage -2 | shrinks | 628 -> **534** ✅ |
| caught by a test? | silver-to-gold count check | **No: build passed PASS=9** |
Rows only moved between buckets; totals and relationships stay valid. **Tests check structure; they can't check meaning.** Fix: a semantic test that computes the expected answer a different way (added in Step 6: `assert_orphan_bucket_matches_silver`).

### Step 4a. `fct_member_month` (the PMPM denominator)
**Goal:** a spine: one row per member per month covered.
- Business rule = counting day, parameterized: `var('member_month_counting_day', 15)`.
- `bounds` -> `months`: `unnest(generate_series(first_month, last_month, interval 1 month))`; month end = `month_start + interval 1 month - interval 1 day`. Spine ends at the latest load date, not "today".
- `counted`: point-in-time join on the 15th (`month_start + 14`).
- `days`: overlap test `v.effective_from <= month_end and v.effective_to >= month_start`; overlap days = `least(end) - greatest(start) + 1`; summed across versions -> fractional member months.
- `member_month_key` = grain as a column (for `unique`); `member_month = 1` makes the measure additive.

**Results:** PASS=4.
| Counting rule | Aug | Sep | Oct | Treats differently |
|---|---|---|---|---|
| any day | 2,614 | 2,654 | 2,628 | generous |
| 1st of month | 2,614 | 2,654 | **2,598** | misses 30 adds starting Oct 2 |
| **15th (chosen)** | 2,614 | 2,654 | 2,628 | middle ground |
| last day | 2,614 | **2,624** | 2,628 | misses 30 mid-Sep terms |
| fractional | 2,614 | 2,644.5 | 2,627 | most precise |
Member D: Sep counts in PPO_RX_B. Member E: Sep in PPO_RX_A, 20 covered days = 0.667 fractional, no Oct row.
Experiment: `--vars '{member_month_counting_day: 1}'` -> Oct drops 2,628 -> 2,598.

### Step 4b. `mart_client_month_metrics` (the client report)
- **Never join two facts row-to-row.** Aggregate each to the shared grain (client x plan x month) first, then join.
- `count(*) filter (where ...)` = filtered aggregate. GDR denominator excludes unknown NDCs.
- `full outer join`: keeps claims with no members (UNATTRIBUTED spend) and members with no claims.
- `nullif(member_months, 0)`: no divide-by-zero; UNATTRIBUTED PMPM is honestly blank.
- `is_complete_month` flag; months without claims data excluded.

**Four traps (all shown on our data)**
| Trap | Evidence | Rule |
|---|---|---|
| Incomplete months | PMPM Aug $64.68, Sep $2,493.58, Oct $75.99 (1 day of claims vs a full month of members) | flag complete months; medical claims call this **runout** |
| Population mismatch | all spend / MM = $2,493.58; attributed / MM = **$2,404.70** | numerator and denominator from the same conformed dim |
| Averaging ratios | CL001 correct $2,630.34 vs averaged $2,631.70; toy: $100 & $300 -> avg $200, true $250 | store additive pieces; re-divide sums |
| Benchmark | $2,404 PMPM vs ~$100-150 real | investigate before publishing |
Plus: Member D's Sep member month sits in PPO_RX_B but 3 Sep fills ($483.90 among them) went to PPO_RX_A, so PPO_RX_A PMPM is slightly overstated. That is the price of a single counting day; fractional MM fixes it.

### Step 5. Rebate reconciliation
- `int_rebates` (silver): latest file wins per quarter x NDC (statuses move INVOICED -> COLLECTED / DISPUTED); reuses the Class 2 `clean_amount` macro.
- `rpt_rebate_reconciliation` (gold): dispensed units from paid claims (brands only) vs invoiced units, full outer join, 2% tolerance, gap = expected - invoiced.
- Trust flags: `quarter_closed`, `claims_coverage_pct` (we hold 33.7% of Q3 = Aug 31-Sep 30) -> `recon_confidence`.

| Q3 drug | Dispensed | Invoiced | Gap | Status |
|---|---|---|---|---|
| Jardiance-like | 55,498 | 1,738 | +$273,998.60 | under-invoiced |
| Eliquis-like | 69,823 | 4,433 | +$152,286.77 | under-invoiced |
| Brandastatin | 30,113 | 4,407 | +$63,403.84 | under-invoiced |
| Semaglutide-like | 1,753 | 4,318 | -$666,356.74 | over-invoiced |
| Tirzepatide-like | 1,095 | 2,423 | -$534,361.57 | over-invoiced |
| Adalimumab-like | 679 | 952 | -$191,181.43 | over-invoiced |
- Q3 under-invoiced **+$489,689.21: conclusive as a lower bound** (missing claims can only make the gap bigger).
- Q3 over-invoiced -$1.39M: **inconclusive** (July-August claims could explain it).
- Q4: **wait, quarter still open** (an invoice before quarter close is itself a source issue).
- Generator invents invoice units at random, so gaps are far bigger than real life; the logic is what transfers.

### Step 6. Tie-out and semantic tests
| Test | Proves | Type |
|---|---|---|
| `assert_gold_fact_ties_to_silver_paid_fills` | gold fact = silver paid fills, to the row and cent | tie-out |
| `assert_orphan_bucket_matches_silver` | -1 bucket = paid fills with no eligibility record, computed independently (anti-join) | **semantic** |
| `assert_covered_fills_fall_inside_member_version` | point-in-time correctness | logic |
| `assert_mart_ties_to_fact` | client report accounts for every dollar, fill and member month | tie-out |
| `assert_gross_cost_equals_patient_plus_plan` | business identity (warn: coupons can break it) | rule |
| `_gold_models.yml` | unique / not_null on every key and grain, relationships fact -> dims, accepted_values on recon_status | structure |
Re-breaking Experiment 2: the tie-out test **passes**, the semantic test **FAIL 1** (expected 100, actual 194). Gap closed.

### Validation pass (after my build)
1. **`rpt_rebate_reconiliation.sql` (typo).** The model got the misspelled name, so the YAML entry `rpt_rebate_reconciliation` matched nothing and its `accepted_values` test was **silently skipped**. dbt only logged "Did not find matching node for patch". Build showed TOTAL=78 instead of 79. Same lesson as Class 2 (`int_pharmacy_claims__types`). Fixed by renaming; TOTAL=79, 52 tests. Guard in CI: `--warn-error-options '{"include": ["NoNodeForYamlKey"]}'` and watch the node count.
2. `assrt_mart_ties_to_fact.sql` renamed to `assert_...` (convention only; dbt runs any .sql in tests/).
3. README Class 4 status set to done.
4. If dbt on the Mac behaves oddly after this, run once with `--no-partial-parse` (target/ was rebuilt from another environment).

---

## Part 3. My questions during class (observations) and the answers

### Q1. Why not keep eligibility as SCD2 too? Without history we can't do RCA on "no coverage" claims.
We do keep it, in three places. Only two things are SCD1, on purpose.
| Layer | Model | History? | Answers |
|---|---|---|---|
| bronze | every raw 834 file by load_date | full, never overwritten | "what exactly did the client send on Oct 1?" (replayable truth) |
| snapshot | `snap_member_eligibility` | SCD2 on **system time** | "what did we believe on date X?" |
| silver spans -> gold | `int_member_coverage_spans` -> `dim_member` | SCD2 on **business time** | "what coverage was true on date X?" |
| silver | `int_eligibility` | SCD1 by design | "who is enrolled right now?" |
| gold | dim_member demographics | SCD1 by design | corrections fix history |

RCA needs **both clocks** (bitemporal). Member E:
| DOS | Submitted | Plan paid | What we knew then | Verdict |
|---|---|---|---|---|
| Sep 25 | Sep 25 10:04 | $197.55 | active (term not sent yet) | not a PBM error; recover from client/member |
| Sep 28 | Sep 28 09:12 | $1.10 | active | same |
| Sep 30 | Sep 30 14:53 | $0.00 | active | same |
| Oct 1 | Oct 1 17:31 | $197.55 | term file arrived that day | investigate: loaded before 17:31? then adjudication error |
Caveat: our snapshot's `dbt_valid_from` shows Oct 17 (when Class 3 ran). A snapshot records history only from when it starts running, which is why bronze is never deleted.
Demographics become SCD2 only when the old value was true and is reported on (e.g. state of residence for networks/mandates). Version what the business reports on; bronze keeps the rest.

### Q2. Is bronze always initial load + day 1..n, with silver processing each day's slice incrementally into intermediate tables, then gold?
Yes, with three refinements:
1. **Silver = today's slice + its own accumulated state.** Fill A: Oct 1 file only has the B2; fills recomputes Fill A from both transactions -> reversed. Incremental = process what changed, decide with full context.
2. **Silver keeps history where the business needs it** (typed transactions = audit trail; snapshot = eligibility versions) and collapses it where it doesn't (fills = final state; int_eligibility = current).
3. **Silver and gold are disposable; bronze is not.** `--full-refresh` rebuilds from bronze (Class 3 test proves incremental = full recompute). Exception: snapshots can only be rebuilt by replaying bronze files in order.
| | Claims (deltas) | Eligibility (834 full file) |
|---|---|---|
| daily file | new transactions only | whole roster again |
| bronze growth | small | roster x days (~1M rows/yr per client) |
| silver | merge new transactions | latest wins + snapshot of changes only |

### Q3. How do silver incremental/snapshot loads work, and are gold facts/dims always full refresh?
- Silver incremental = `materialized='incremental'` + strategy (merge / delete+insert / append) + `unique_key` + an `{% if is_incremental() %}` filter (new slice + lookback). First run or `--full-refresh` skips the filter.
- Snapshot = dbt compares current rows with open versions (`check` or `timestamp`), closes changed rows, inserts new versions.
- **Gold today = `table` (full rebuild) on purpose:** correct by construction, sub-second at our size. Make it right, then make it fast.
| Model | Production strategy | Why |
|---|---|---|
| dim_drug, dim_provider, rpt_rebate | full rebuild | tiny |
| dim_member | full rebuild from spans | history lives in the silver snapshot |
| fct_pharmacy_claim | incremental, delete+insert on fill_key | the only big one |
| fct_member_month, mart | rebuild a trailing window (3-6 months) | retro changes hit recent months |
- Incremental fact must reprocess **touched fills AND touched members**: a retro-term (Member E) changes old fact rows with no new claim arriving. Deterministic md5 keys make reprocessing safe.
- **Frequency vs strategy:** orchestrator decides *when* (every file drop: one `dbt build` runs bronze -> silver -> snapshot -> gold); materialization decides *how*. Weekly `--full-refresh` as a safety net.

---

## Part 4. Expected interview questions by step (with answers)

**Business primer**
- *Q: What is PMPM and why use it?* Plan paid divided by member months. It normalizes for client size and time, so a 500-member and a 50,000-member client can be compared.
- *Q: Rebate vs rebill?* Rebate = manufacturer money paid to the PBM for brand placement, invoiced quarterly. Rebill (B3) = a corrected pharmacy claim.
- *Q: Why are brands and specialty the focus of cost management?* Generics are ~76% of our fills but ~2% of plan spend; specialty is a few percent of scripts but most of the spend.

**Step 1: dimensions, surrogate keys**
- *Q: Why surrogate keys instead of natural keys?* They version history (SCD2), let unknown rows exist (-1), and insulate facts from source ID formats. md5 makes them deterministic, so reprocessing gives the same key.
- *Q: How do you handle a fact row whose dimension value is missing?* Point it to a special Unknown row, never NULL, so inner joins keep it, row counts tie out, and the gap is visible and countable.
- *Q: What is a role-playing dimension?* One dimension joined in several roles, e.g. dim_provider as pharmacy and as prescriber, or dim_date as order and ship date.

**Step 2: SCD2 member dimension**
- *Q: SCD1 vs SCD2?* SCD1 overwrites, SCD2 adds a version with effective dates. I decide per column: a correction is SCD1, a real dated event is SCD2.
- *Q: How do you build an SCD2 dimension in dbt?* Snapshot the source (check strategy for full files), derive business-effective spans, then build the dim with a surrogate key of natural key + effective_from, and test that key for uniqueness and spans for non-overlap.
- *Q: What PHI belongs in gold?* Only what consumers need: no names, zip3, masking by role; names stay in silver for operations.

**Step 3: the fact**
- *Q: What's the grain of your claims fact and why?* One row per final paid fill after reversal netting. Per transaction would double-count B1 + B3.
- *Q: What's a fan-out and how do you prevent it?* A join to a table with multiple rows per key multiplies rows. Prevent with point-in-time conditions on SCD2 joins, and catch it with a unique test on the fact grain. On my data a naive join overstated spend by $119K.
- *Q: Why put a filter in the ON clause of a left join?* In WHERE it removes the unmatched rows and silently turns the left join into an inner join.
- *Q: All your tests are green; are the numbers right?* Not necessarily. Structural tests can't catch a wrong business definition. I add semantic tests that compute expected answers independently, and review breakdowns with the business.

**Step 4: member months, metrics**
- *Q: How do you count member months?* Covered on a counting day (we use the 15th), parameterized as a variable. Any-day, first-of-month and fractional are alternatives; it's a contract definition, and a 1% denominator change moves PMPM 1%.
- *Q: What goes wrong with PMPM?* Incomplete months (runout), numerator and denominator from different populations, averaging ratios across plans, and not checking against benchmarks.
- *Q: How do you combine two facts with different grains?* Aggregate each to the shared grain first, then join (full outer), never row-to-row.
- *Q: What is GDR and how do you treat unknown drugs?* Generic fills / fills with a known drug; unknown NDCs are excluded from the denominator, not counted as brand.

**Step 5: rebates**
- *Q: How would you reconcile rebates?* Dispensed units from paid claims times the contract rate vs invoiced units per quarter and NDC, full outer join, with a tolerance.
- *Q: Your reconciliation shows an over-billing; do you dispute?* Not until the quarter is closed and we hold the whole quarter's claims. With partial data, under-billing is provable as a lower bound, over-billing isn't.

**Step 6: tests**
- *Q: What tests do you put on a gold layer?* Unique/not_null on every grain and key, relationships to dims, accepted values on status columns, tie-outs from silver to gold and gold to marts, semantic checks against independently computed answers, and warn-level business identities.
- *Q: Have you seen a test silently not run?* Yes: a misspelled model file meant the YAML test never attached; dbt only warned. I watch node counts and make NoNodeForYamlKey an error in CI.

**Architecture (from my questions)**
- *Q: Walk me through your layers.* Bronze append-only and replayable; silver incremental on today's slice plus accumulated state, keeping history only where needed; gold shaped for consumers and rebuildable; snapshots protected because only replay can rebuild them.
- *Q: How do you refresh gold?* Full rebuild until it hurts; then incremental delete+insert on the fact grain, reprocessing touched fills and touched members; dims full rebuild; weekly full refresh.
- *Q: A claim was paid after termination. Whose fault?* Check both clocks: if the termination arrived after the fill, it was paid correctly and is recovered from the client; if before, it's an adjudication error.

## Part 5. 30-second answers
- **Dimensional model:** "For pharmacy claims I declared the grain first: one row per final paid fill after reversal netting. Member, drug and provider dimensions with md5 surrogate keys; the member dimension is SCD2 on coverage dates, and the fact joins it point-in-time on date of service, so a retro plan change never rewrites history. Unmatched rows go to unknown or no-coverage rows instead of NULLs, and tests prove gold ties to silver to the cent."
- **PMPM:** "Plan paid over member months, both from the same conformed member dimension. I flag incomplete months, keep unattributed spend out of client numerators, never average ratios, and check against benchmarks before publishing."
- **Rebates:** "Dispensed units times contract rate vs invoiced units per quarter and NDC. A reconciliation should state its confidence: under-billing is provable on partial data as a lower bound, over-billing isn't."
- **Impact story:** "Point-in-time eligibility surfaced about $196K of claims paid after retro-terminations, a recovery list the client can act on. Using both clocks, I can separate claims paid correctly before the termination arrived from true adjudication errors."
- **Testing:** "Green tests don't prove correct numbers. In my project a bucket-definition bug moved 94 claims from orphan to no-coverage and every structural test passed; I added a semantic test that computes the expected answer independently, and now it fails."

---

## Part 6. Session thread (how the class actually ran)
1. 08:37 Progress check: Classes 1-3 done, Rightway 1st round Tue (Director, general assessment). Plan: Class 4, then mock interview.
2. 08:42 Class 4 started; Claude first built everything end to end to validate the design (found the 194-vs-100 orphan definition bug while doing so).
3. 08:56 Switched to type-along mode: reset the gold folder, Claude dry-runs each step on a copy, Piyoosh types every file.
4. Step 1 dims built, PASS=5; check question answered (false vs null) with a correction on spend vs classification.
5. Step 2 dim_member built, PASS=9; break-it experiment FAIL 80.
6. Q1 (eligibility SCD2 for RCA) -> bitemporal answer with Member E. Q2 (bronze/silver/gold flow) -> three refinements.
7. 11:50 Time check: re-planned (finish Class 4 today, mock interview tonight, slim Class 5 Monday, Class 6 after Tuesday).
8. Step 3 fact built; both experiments run; learned the fan-out has two opposing effects and that tests can't check meaning.
9. Step 4a member months + counting-day experiment.
10. Q3 (incremental/snapshot in silver, gold refresh strategy) answered.
11. Steps 4b-6 built; full build PASS=76/TOTAL=78 committed (f2dded3).
12. Validation: misspelled rpt file skipped one test; renamed, README updated, full build PASS=77/TOTAL=79; notes rewritten and pushed.
