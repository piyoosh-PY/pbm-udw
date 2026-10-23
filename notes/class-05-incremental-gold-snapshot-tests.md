# Class 5: Incremental gold, gold snapshot, unit tests (live, 2026-10-21 / 22)

**Format:** typed by hand, step by step (the crash version I first got on Oct 19 lives on branch `class5-reference`).
**Final state:** Oct 3 + Oct 4 loads processed incrementally, all tests green; 2 unit tests pass.
**Not done yet (Part 1 remainder + Part 2):** custom generic tests, model contract, GitHub Actions CI, pytest, Dagster. Reference code for all of them is on `class5-reference`.

## Files built
| File | What |
|---|---|
| `models/gold/fct_pharmacy_claim.sql` | table -> **incremental** (delete+insert on fill_key), 3 change triggers, `depends_on` hint, `post_hook` delete path, audit columns `_silver_processed_at`, `_gold_loaded_at` |
| `models/silver/int_member_coverage_spans.sql` | **bug fix:** drop empty spans (effective_to < effective_from) from retro corrections |
| `tests/assert_fct_has_no_reversed_or_rejected_fills.sql` | regression test for the delete path |
| `snapshots/snap_client_month_metrics.yml` | **gold mart snapshot**: restatement history of the client report |
| `analyses/pmpm_restatements.sql` | which client-months changed after first publish, and by how much |
| `models/gold/_gold_unit_tests.yml` | 2 **unit tests**: point-in-time + special rows; incremental triggers |

---

## Step by step (with my answers and corrections)

### Step 0. Baseline
- Got `PASS=71 ERROR=1 SKIP=5` instead of 77: seed `toy_orders` looked for a `/sessions/...` path.
- **Cause:** stale **partial-parse cache** (`target/partial_parse.msgpack`) written by a run from another environment. **Fix:** `dbt clean` then `dbt build` -> 77.
- Lesson: when dbt behaves impossibly (old paths, stale vars), clear the cache first (`dbt clean` / `--no-partial-parse`). CI always starts from a clean `target/`.

### Step 1. Which events make an old gold row wrong?
- **My answer:** late eligibility (orphan gets a real member). I said claims can't change "because we only load paid fills".
- **Correction:** claims DO change after load: **late reversal (B2)** (paid -> reversed; "we only load paid" is exactly why it's dangerous: the reversal never enters the batch), **rebill (B3)** (same fill_key, new amounts), **retro eligibility** (term / plan change: member was known, so "late eligibility" doesn't catch it), plus **late drug file**.
| # | Trigger | Catches |
|---|---|---|
| a | silver touched the fill since gold's last load (**watermark**) | new fills, rebills, late reversals |
| b | row parked on a special row (`-1`/`-2`, unknown drug) | late eligibility, late drug file |
| c | member's eligibility changed since gold's last load (**snapshot as change feed**) | retro term, retro plan change |
| + | **delete path** | paid -> reversed (never re-inserted) |

### Step 2. Make it incremental (trigger a)
- Config: `materialized='incremental'`, `incremental_strategy='delete+insert'`, `unique_key='fill_key'`, `on_schema_change='fail'`.
- Editing slip: a paste landed mid-select-list (joins before `from`, merged lines). Fix: `git checkout -- <file>` and redo 3 small edits. **Habit: `git diff` before every `dbt run`.**
- Config keys are lowercase (`materialized`, not `MATERIALIZED`).
- First run failed: `Binder Error: Referenced column "_silver_processed_at" not found`.
  - **Why (precise):** table exists -> `is_incremental()` true -> SQL reads a column the OLD table doesn't have. **Rule: change columns or materialization -> `--full-refresh` once.**
- After full refresh: 24,060 rows. A second `dbt run -s fct_pharmacy_claim` rebuilt **0** rows: only gold ran, silver's `_processed_at` didn't move.

### Step 3. Trigger (b): parked rows
- **Prediction (correct): 902, not 908** (100 orphans + 628 no-coverage + 180 unknown drug = 908; 6 fills are both -2 and unknown drug). `or` counts a row once. **Count rows, not conditions.**

### Step 4. Trigger (c): retro eligibility via the snapshot
- Slip: only the `where dbt_valid_from ...` line went in, into `known_members` (reads `int_eligibility`, no such column). `known_members` must stay untouched.
- The real gotcha: **"dbt was unable to infer all dependencies"**. dbt finds `ref()`s at **parse time**, when `is_incremental()` is false, so a ref only inside the if-block is invisible. Without the DAG edge, gold could run before the snapshot updates.
- **Fix:** `-- depends_on: {{ ref('snap_member_eligibility') }}` (a SQL comment is still rendered by Jinja at parse time).
- Trigger (c) compares to `_gold_loaded_at` (when gold last looked), not the silver watermark.

### Step 5. Full build without new data
- `PASS=77`; ~5,600 gold rows rebuilt with no new file.
- **My answer:** orphans got eligibility. **Correction:** no new file = nothing resolved. **Lookbacks cascade:** silver re-reads the last N load dates and re-checks DQ-flagged rows every run -> new `_processed_at` -> gold watermark fires. Safe (idempotent), just extra work. Tune lookback to real lateness; compare row hashes to avoid no-op rebuilds.

### Step 6–8. Oct 3 load: the upstream failure
- **Prediction:** (B) gold fails. **Actual:** `unique_dim_member_member_sk FAIL 2`, `SKIP=21` (dbt skipped everything downstream: a broken dim never feeds the fact).
- Debug path: test -> rows -> raw history. Members RW102014-01, RW102055-01: **new add (021)** then a **retro change (001) dated before coverage start** -> v2 starts the same day as v1 -> v1 = Oct 1 -> Sep 30 (**empty span**) -> both hash to `md5(member_key | Oct 1)`.
- **My fix idea:** add version_number or effective_to to the key. **Why not:**
  - `effective_to` **changes** (open 9999-12-31 -> closed when the next version arrives) -> key changes -> fact rows orphaned. **Surrogate keys only use values that never change for that version.**
  - version_number keeps a garbage row ("was this member ever on HDHP?" -> wrongly yes).
- **Right fix:** drop spans never in force for a day, in **silver** (`where effective_to >= effective_from` after `lead()`; filtering earlier breaks `lead()`).
- Lesson: **fix the cause, not the test.** Ask "is the data wrong or the key?" before changing a key.

### Step 9–10. The delete path
- `assert_gold_fact_ties_to_silver_paid_fills` failed: **80 reversed fills, $22,497.85** still in gold.
- **My diagnosis (correct):** watermark pulls them, but `where fill_status = 'paid'` drops them before delete+insert, which only deletes keys in the batch.
- I proposed `hard_deletes: invalidate` -> that's a **snapshot** setting; incremental models have no delete setting.
- **Options:** soft delete flag (grain changes; consumers forget the filter) / **MERGE with delete branch** / **post_hook delete**.
- **My question: why not MERGE?** Atomic and targeted, reads like the rule. But dbt's built-in merge has no delete branch -> needs a custom incremental strategy or adapter-specific option (e.g. Databricks `not_matched_by_source_action`), batch must carry non-paid rows but never insert them, syntax differs by warehouse. Post_hook = simple, portable, idempotent (deletes every non-paid fill each run, self-heals); trade-off: small non-atomic window.
- No full refresh needed for the hook (columns unchanged). Result: `PASS=77`.

### Step 11. Regression test
`assert_fct_has_no_reversed_or_rejected_fills`: a singular test = a query returning bad rows; 0 rows = pass; failing rows = the answer.

### Step 12. Gold standard proof (optional, not yet run by me)
Incremental result == full-refresh result (EXCEPT both directions, excluding audit columns). On the reference copy: 0 and 0.

### Step 13–14. Gold mart snapshot (restatements)
- Hit **dbt Fusion** errors (`UnusedConfigKey dbt1060`, `loaded_at_field`): new terminal, venv not active, `dbt` resolved to a v2 install. Fix: `source .venv/bin/activate`, `which dbt`, `dbt --version`. Lesson: **pin dbt per project (venv + requirements, same version in CI).**
- `snap_client_month_metrics`: `unique_key` = mart grain (client, plan, month), `strategy: check` (no trustworthy updated_at), `check_cols` = client-visible numbers only, `hard_deletes: invalidate`, `dbt_valid_to_current` 9999-12-31.
- First run 30 rows. **My answer (correct):** rerun adds nothing (check strategy, nothing changed). Holds even after a rebuild if values are identical.
- Oct 4 load -> `PASS=78`, **20 client-months restated**. CL001 / PPO_RX_A / Sep: **paid fills 2,755 -> 2,731** (late reversals took claims away).
- Interview answer: lead with "data changed after we published", show both versions with timestamps and the cause in client words, then prevention: a "still settling" flag + agreed close date (claims run-out).
- Faster querying: DuckDB UI (`duckdb -ui`), DuckDB CLI `-readonly`, Harlequin, DBeaver / VS Code. Schemas are `main_gold`, `main_snapshots`. One writer at a time: open read-only, close before `dbt build`.

### Step 15. Unit tests
- Data test = checks data after build; **unit test = checks logic before build on hand-made rows**, including edge cases today's data doesn't have.
- `overrides: macros: is_incremental: false/true`; `input: this` fakes yesterday's gold; every `ref` needs a `given` (incl. the snapshot because of `depends_on`), `rows: []` = empty.
- YAML slip: `desciption` typo -> "Additional properties are not allowed"; test 1 header ended up with test 2's body.
- **Break-it:** disable trigger (c) -> diff `---,F3,-2` (daff: `---` = expected but missing). F3 never entered the batch -> a retro-termed claim stays "covered": PMPM attributed wrongly, recovery missed. **No data test catches this (counts, keys, relationships all still valid); only a unit test on the logic does.**
- Gotcha: unit tests on an incremental model read column types from `{{ this }}` -> in a fresh database build first, then unit-test.

---

## 30-second answers
- **Incremental gold fact:** "Before writing SQL I list every reason an old row can change: new fills, rebills and late reversals, late eligibility, retro terms and plan changes. Each gets a trigger: a silver watermark, a retry of rows parked on unknown rows, and the eligibility snapshot as a change feed. Deletes get their own path, a post-hook, because delete+insert only touches keys in the batch. I prove it with incremental equals full refresh, plus unit tests on the trigger logic."
- **Bug the tests caught:** "A new eligibility file broke a surrogate key: a new enrollment followed by a retro change dated before coverage start made an empty span, and two versions hashed the same. The tempting fix was more columns in the key, which hides a bad row and makes keys unstable. I fixed the span logic in silver."
- **Restatements:** "We snapshot every published version of the client report. When September changes after late reversals, I can show both versions with timestamps and the exact claims that drove it."
- **Unit vs data tests:** "Data tests check the data I have; unit tests check the logic against cases I don't have yet. Disabling one trigger left a retro-termed claim marked covered, and every data test still passed."
