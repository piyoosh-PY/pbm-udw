# Class 5 (crash version): testing, incremental gold, gold snapshots, CI (2026-10-19)

Interview-eve crash course: ~90 minutes. Hands-on first (you run it, the code is already written), then the
theory for the rest of Class 5 and all of Class 6, then short interview answers.
The full deep-dive versions of Classes 5 and 6 stay on the plan for after the interview.

**Time plan**
| Min | Block | What |
|---|---|---|
| 0-10 | A1-A2 | Read the incremental fact, switch it from table to incremental |
| 10-25 | A3-A4 | Snapshot of the gold mart, new load with late reversals + retro eligibility |
| 25-40 | A5-A6 | Unit tests, custom generic tests, model contract |
| 40-55 | A7-A9 | Break-it experiments, slim CI demo, CI workflow |
| 55-80 | B | Theory: rest of Class 5 + Class 6 (AWS) |
| 80-90 | C | Say the 30-second answers out loud |

**Files added / changed today**
| File | What |
|---|---|
| `models/gold/fct_pharmacy_claim.sql` | table -> **incremental** (delete+insert, 3 change triggers, post_hook for tombstones, audit columns) |
| `models/silver/int_member_coverage_spans.sql` | **bug fix** found by the new load: drop superseded zero-day spans |
| `snapshots/snap_client_month_metrics.yml` | **snapshot of the gold mart** (restatement history) |
| `analyses/pmpm_restatements.sql` | which client-months changed after first publish |
| `models/gold/_gold_unit_tests.yml` | 3 **unit tests** (point-in-time, incremental logic, divide-by-zero edge) |
| `tests/generic/non_negative.sql`, `unique_combination_of_columns.sql`, `max_share.sql` | **custom generic tests** |
| `tests/assert_fct_has_no_reversed_or_rejected_fills.sql` | proves the post_hook works |
| `models/gold/_gold_models.yml` | **contract** on dim_drug, generic + threshold tests, `store_failures`, `where` |
| `.github/workflows/dbt-ci.yml`, `requirements.txt` | **CI** on every PR |

Setup for every step:
```bash
cd ~/CodeBase/pbm-udw && source .venv/bin/activate && cd pbm_dbt
```

---

## Part A. Hands-on walkthrough

### A1. Read the incremental fact (5 min)
Open `models/gold/fct_pharmacy_claim.sql`. Read the header comment, then the `fills` CTE.

**Why incremental at gold?** The fact is the biggest table. Rebuilding 24K rows is free here; rebuilding 2 billion
claims every hour in Snowflake is not. Incremental = only touch the rows that could have changed.

**The hard part is not "new rows". It's knowing every reason an OLD row can change.** Three triggers:
| Trigger | Real-world cause | SQL |
|---|---|---|
| (a) watermark | new fills, rebills (B3), late reversals (B2) | `_processed_at > max(_silver_processed_at) in this` |
| (b) parked rows | claim arrived before eligibility / drug file (late-arriving dimension) | `fill_key in (rows of this with -1 / -2)` |
| (c) dimension change | retro plan change, retro termination in the 834 | `member_key in (snapshot rows with dbt_valid_from > our last load)` |

Plus **deletes**: `delete+insert` deletes the keys it is about to insert, then inserts. A fill that was paid and is
now reversed is not inserted (grain = paid only), so its old row would stay forever. The `post_hook` deletes it.

Three things to notice in the code:
- `-- depends_on: {{ ref('snap_member_eligibility') }}`. dbt reads refs at **parse time**, when `is_incremental()` is false, so a ref that only appears inside the `if` block is invisible. Without the hint: *"dbt was unable to infer all dependencies"*.
- Audit columns `_silver_processed_at` (the watermark) and `_gold_loaded_at` ("when did gold learn this?").
- `on_schema_change='fail'`: if the columns change, stop instead of silently drifting. Fix with `--full-refresh`.

### A2. Switch the table to incremental (5 min)
**Try the normal run first (it should fail):**
```bash
dbt run -s fct_pharmacy_claim
```
Expected: `Binder Error: Referenced column "_silver_processed_at" not found`.
**Why:** the table already exists, so `is_incremental()` is TRUE, and the incremental SQL reads a column the old table doesn't have.
Rule: **changing a model's columns or materialization = one `--full-refresh`**.

```bash
dbt run --full-refresh -s fct_pharmacy_claim
```
Use `run`, not `build`: `build` would first run the unit test on the incremental logic, which reads the column types
of the fact itself and the old table doesn't have the new columns yet (same reason CI builds before unit-testing).
Expected: OK. 24,060 fills, $6,986,722.16 (same as Class 4; nothing lost).

```bash
dbt build
```
Expected: `PASS=87 WARN=2 ERROR=0 TOTAL=89` (the 2 warns are the same expected ones from Class 4).

```bash
dbt show --inline "select _gold_loaded_at, count(*) from {{ ref('fct_pharmacy_claim') }} group by 1 order by 1"
```
Expected: **18,437** rows from the full refresh, **5,623** rebuilt on the incremental run.
**Check question:** no new file arrived, so why were 5,623 rows rebuilt?
<details><summary>Answer</summary>
Lookbacks cascade. Silver re-reads the last load dates (`claims_lookback_days`) and re-checks rows with soft DQ flags every run,
so their `_processed_at` moves forward, so gold sees them as touched. That's correct and safe (idempotent), just extra work.
In production you'd tune the lookback against how late data really arrives.
</details>

### A3. Snapshot of the gold mart (5 min)
Open `snapshots/snap_client_month_metrics.yml`. The `dbt build` you just ran already created it (30 rows, one per client x plan x month).

**The business problem:** the mart is a table, rebuilt every run. On Oct 2 we send CL001 its September report.
On Oct 3 late reversals arrive, the mart is rebuilt, September changes, and the old number is gone. The client asks
*"why is September different from what you sent us?"* and we can't prove what we published.
**The fix:** snapshot the mart. Every run, dbt compares `check_cols` per key; if a value changed it closes the old
row (`dbt_valid_to`) and opens a new one.

Config choices to be able to explain:
- `unique_key: [client_id, plan_id, service_month]`: the mart's grain, composite key (dbt 1.9+ allows a list).
- `strategy: check`: the mart has no trustworthy `updated_at`, so compare values. (`timestamp` strategy is cheaper when the source has a reliable updated_at.)
- `check_cols`: only the numbers a client sees. Don't put `current_timestamp` columns in there or every run is a "change".
- `hard_deletes: invalidate`: a client-month that disappears gets closed, not left looking current.
- Snapshot time = **system time** (when we published), not business time.

**Two kinds of "snapshot" in interviews, don't mix them up:**
| | dbt snapshot (SCD2 of a table) | Kimball periodic snapshot fact |
|---|---|---|
| Question | how did this row change over time? | what was the state at the end of each period? |
| Grain | one row per key per version | one row per key per period (e.g. member x month-end) |
| Example here | `snap_client_month_metrics`, `snap_member_eligibility` | `fct_member_month` is close: member x month, covered on the 15th |
| Build | `dbt snapshot` | incremental model that appends one period at a time |
Third kind: **accumulating snapshot** = one row per process instance, updated as milestones happen (e.g. prior auth: submitted -> reviewed -> approved -> first fill).

### A4. New load: late reversals + retro eligibility (10 min)
```bash
cd ~/CodeBase/pbm-udw
python generator/generate_pbm_data.py --load-date 2026-10-03 --late-reversals --claims 3000 --window-days 3
cd pbm_dbt && dbt build
```
Expected: `PASS=87 WARN=2 ERROR=0` (warns grow to 600 duplicate transaction_ids and 130 orphans, expected).

What happened in the fact (my dry run on a copy of your warehouse; yours should match):
| | Before Oct 3 | After Oct 3 |
|---|---|---|
| Fills | 24,060 | **26,552** |
| Plan paid | $6,986,722.16 | **$7,644,239.97** |
| covered | 23,332 | 25,597 |
| -2 (no coverage on DOS) | 628 | 825 |
| -1 (orphan) | 100 | 130 |

Where the change came from:
| Change | Rows | Plan paid | Trigger |
|---|---|---|---|
| new fills | 2,572 | | (a) watermark |
| paid -> reversed, deleted by post_hook | **80** | $22,497.85 | (a) + post_hook |
| member version -> other version (retro plan change) | 122 | $33,693.67 | (c) snapshot |
| member version -> `-2` (retro termination) | 53 | $16,686.64 | (c) snapshot |
| `-1` -> member version (late eligibility) | 10 | $1,402.26 | (b) parked rows |
Rows rebuilt this run: 8,386; untouched: 18,166.

**Proof the incremental result is right:** I saved the incremental fact, ran `--full-refresh`, and compared both ways with `EXCEPT`: **0 rows different**.
This is the gold standard test for any incremental model: **incremental result = full-refresh result**.
(Your existing `assert_gold_fact_ties_to_silver_paid_fills` is the cheap always-on version: same count and same dollars as silver.)

Now look at the restatements:
```bash
dbt show -s pmpm_restatements --limit 50
```
Expected: snapshot 50 rows, **20 client-months restated**. Example CL001 / PPO_RX_A / September:
| version | published | paid fills | member months | plan paid PMPM |
|---|---|---|---|---|
| 1 | first build | 2,661 | 306 | $2,899.77 |
| 2 | after Oct 3 | 2,755 | 306 | $2,987.63 |
That's the answer to the client: "September went up $87.86 PMPM because 94 more September fills arrived late; here are the two versions with timestamps."

**The bug this load found (interview story).** Before today's fix, this exact load failed `unique_dim_member_member_sk` with **FAIL 2**.
Members RW102014-01 and RW102055-01 were brand-new adds (021) that then got a retro plan change (001) dated before their coverage start.
v2 started the same day as v1, so v1 became an empty span (effective_to < effective_from) and both versions got the same
`member_sk = md5(member_key | effective_from)`. Fix in `int_member_coverage_spans.sql`: drop spans that were never in force for a day.
Optional experiment: comment out the last `where effective_to >= effective_from` line, `dbt build`, see FAIL 2, restore.
> "A new feed pattern broke a surrogate key; the unique test caught it before gold published; the fix went in silver, where the span logic lives, not as a patch in gold."

### A5. Unit tests (8 min)
Open `models/gold/_gold_unit_tests.yml`.

| Data test | Unit test |
|---|---|
| checks the **data** after a build | checks the **logic** before a build |
| runs on real tables | runs on 3-5 hand-made rows |
| "is fill_key unique today?" | "if a member is retro-termed, does my SQL move the fill to -2?" |
| catches bad input data | catches bad code, incl. edge cases today's data doesn't have |

```bash
dbt test -s "test_type:unit"
```
Expected: PASS=3.
- `ut_fct_claim_point_in_time_member_and_special_rows`: Sep 10 -> version 1, Sep 20 -> version 2, termed member -> `-2`, orphan -> `-1`, reversed fill absent.
- `ut_fct_claim_incremental_picks_only_changed_fills`: `overrides: macros: is_incremental: true` + `input: this` (the fact as it was). Expect only F2 (late eligibility), F3 (retro term), F4 (new); F1 untouched.
- `ut_mart_pmpm_is_null_not_error_when_no_member_months`: 0 member months -> PMPM NULL, not a crash.

**Experiment:** in `fct_pharmacy_claim.sql`, change `         or member_key in (` to `         or false and member_key in (` (disables trigger c). Run `dbt test -s "test_type:unit"`.
Expected: **FAIL 1** on the incremental unit test, diff shows F3 expected `-2`. Restore the line.
That's exactly what a unit test is for: someone "simplifies" the incremental filter and the retro-termination path silently dies.

Gotcha (CI): unit tests on an incremental model read the column types of `{{ this }}`, so the model's table must exist.
In a brand-new database: build first, unit-test second. That's why the CI workflow has that order.

### A6. Custom generic tests + contract (7 min)
Open `tests/generic/*.sql` and the new entries in `_gold_models.yml`.
- `non_negative`: column-level, the simplest generic test. Any test = a query that returns the bad rows; 0 rows = pass.
- `unique_combination_of_columns`: **grain test** for a composite key (mart = client x plan x month). Same idea as `dbt_utils.unique_combination_of_columns`, hand-written so you can explain it. Has `store_failures: true`: failing rows are saved to a table you can query.
- `max_share`: **threshold** test. 0.75% unknown drugs is normal; 5% means the drug file failed to load. `severity: warn`. Other knobs: `warn_if: ">10"`, `error_if: ">100"`.
- `where: "is_complete_month"` on the PMPM test: test only the rows that matter.

**Contract on `dim_drug`:** names + types declared in YAML, `contract: {enforced: true}`, `not_null` constraint enforced by the database.
**Experiment:** in `dim_drug.sql` change `labeler_name` to `labeler_name as labeler`, run `dbt run -s dim_drug`. Expected:
```
This model has an enforced contract that failed.
| column_name  | definition_type | contract_type | mismatch_reason       |
| labeler      | VARCHAR         |               | missing in contract   |
| labeler_name |                 | VARCHAR       | missing in definition |
```
The table is never built, so BI and downstream models never see the breaking change. Restore.
**Contract vs test:** a contract runs *before* the build and checks the **shape**; a test runs *after* and checks the **values**.
In dbt Mesh, contracts + `access: public` + model `version`s are how one team safely exposes a model to another.

### A7. Break it: no post_hook (7 min)
In `fct_pharmacy_claim.sql` delete the 3 `post_hook=[ ... ]` lines and the comma after `on_schema_change='fail'`. Then:
```bash
cd .. && python generator/generate_pbm_data.py --load-date 2026-10-04 --late-reversals --claims 3000 --window-days 3 && cd pbm_dbt
dbt build
```
Expected (from my dry run): **FAIL ~80** `assert_fct_has_no_reversed_or_rejected_fills`, **FAIL 1** `assert_gold_fact_ties_to_silver_paid_fills` (dollars no longer tie), **FAIL 2** `assert_covered_fills_fall_inside_member_version` (stale reversed rows still point at old versions).
Restore (`git checkout models/gold/fct_pharmacy_claim.sql`), `dbt build` -> back to PASS=87. It self-heals because the hook deletes **every** non-paid fill_key each run, not just this run's (idempotent).
> "delete+insert and merge only touch keys you send. Deletes need their own path: a soft-delete flag, a post-hook, or `merge ... when not matched by source`."

### A8. Slim CI on your laptop (5 min)
```bash
mkdir -p ../.dbt_state && cp target/manifest.json ../.dbt_state/       # pretend this is production's manifest
# edit any line in models/gold/dim_drug.sql (e.g. add a comment), then:
dbt ls -s state:modified+ --state ../.dbt_state --resource-type model snapshot
```
Expected: `dim_drug`, `fct_pharmacy_claim`, `mart_client_month_metrics`, `rpt_rebate_reconciliation`, `snap_client_month_metrics`.
Only the changed model and everything downstream. On a 500-model project, a PR runs 5 models instead of 500.
Undo the edit, then `rm -rf ../.dbt_state`.

### A9. Read the CI workflow (3 min)
`.github/workflows/dbt-ci.yml`: on every PR -> install pinned dbt -> generate the same raw data (deterministic `--seed`) ->
`dbt parse` -> full build without unit tests -> unit tests -> incremental build on top -> upload `manifest.json`.
The incremental-on-top step is the cheap way to prove both code paths (full and incremental) work.
Push to GitHub and it runs automatically (Actions tab). Optional for tonight.

---

## Part B. Theory crash course (rest of Class 5 + Class 6)

### B1. Test pyramid for data
| Layer | What | dbt / tool | Here |
|---|---|---|---|
| Source checks | freshness, row counts vs manifest, schema | `dbt source freshness`, singular tests | `_sources.yml` freshness, `assert_stg_claims_row_count_matches_manifest` |
| Unit tests | logic on fake rows | dbt unit tests, pytest for Python | `_gold_unit_tests.yml` |
| Data tests | values after build | generic (`unique`, `not_null`, `relationships`, `accepted_values`, custom) + singular | 50+ tests |
| Reconciliation | layer-to-layer tie-outs | singular tests | bronze->silver->gold count and dollar tie-outs |
| Contracts | shape before build | `contract: enforced` | `dim_drug` |
| Observability | trends over time: volume, nulls, distribution drift | Elementary, Monte Carlo, `store_failures` history | `max_share` is a tiny version |
**Severity strategy:** `error` = stop the pipeline (grain broken, money doesn't tie). `warn` = known, tolerable, monitored (orphans, duplicates already handled downstream). Every warn should have an owner and a threshold.
**What to test first** (when short on time): grain (unique key) of every model, not_null + relationships on fact FKs, one money tie-out per layer, accepted_values on statuses.

### B2. Incremental strategies (know the table)
| Strategy | How | Good for | Watch out |
|---|---|---|---|
| append | insert new rows only | immutable events (logs) | duplicates on rerun |
| merge | match on unique_key: update or insert | upserts, late updates | expensive scan of the target without partition pruning |
| delete+insert | delete keys in the batch, insert batch | replacing whole groups of rows | not atomic on every warehouse |
| insert_overwrite | replace whole partitions | aggregates by day/month, BigQuery/Spark/Athena | must recompute the full partition |
| microbatch (dbt 1.9+) | dbt splits by `event_time` into batches, each batch replaces its slice | big time-series, easy backfills (`--event-time-start/--end`) | needs a reliable event_time |
**Late data:** lookback window (reprocess the last N days) or a processed-at watermark (what we did). **Deletes:** never handled by default. **Correctness test:** incremental = full refresh. **Schedule a periodic full refresh** (e.g. weekly) as a safety net for anything the triggers miss.
**Incremental aggregate (mart) pattern:** find the months touched this run, recompute those whole months, delete+insert (or insert_overwrite) by month. Never "add today's numbers to yesterday's total": reversals make sums go down.

### B3. CI/CD for dbt
- **CI (PR):** parse -> build changed + downstream (`state:modified+`) with `--defer --state prod_manifest` into a temporary schema -> tests -> drop schema. Blocks merge on red.
- **CD (merge to main):** prod job runs `dbt build` (or a slim deploy), uploads manifest for the next PR's state comparison.
- **Environments:** dev (your schema) / CI (per-PR schema) / prod. Same code, different `target`.
- **Other checks people add:** SQLFluff lint, `dbt docs generate`, dbt-checkpoint/pre-commit (every model has a description + a unique test).

### B4. Orchestration
| Concept | Meaning |
|---|---|
| DAG | tasks with dependencies; dbt already has one inside, the orchestrator runs it plus the non-dbt steps (ingest, ML, reverse ETL) |
| Airflow | task-centric, Python DAGs, scheduler + workers, huge ecosystem; MWAA on AWS |
| Dagster | asset-centric: each dbt model is an asset; lineage, partitions and backfills are first-class |
| Step Functions | AWS-native state machine: Lambda/Glue/ECS steps, retries, catch, parallel branches |
| Idempotency | rerunning the same run gives the same result (merge/delete+insert on keys, not append) |
| Retries | retry transient errors (network, throttling) with backoff; never blindly retry a data-quality failure |
| Backfill | rerun a past date range: partitioned runs or dbt `--vars '{start: ..., end: ...}'` / microbatch `--event-time-start` |
| Sensors / event-driven | start when the file lands (S3 event), not at a fixed time |
| SLA / freshness | "claims mart ready by 7 AM ET"; alert if late; `dbt source freshness` gates the run |

### B5. AWS for a data warehouse (Class 6 in one page)
**Reference architecture for this project:**
```
PBM / TPA / 834 files --SFTP--> S3 landing (raw/feed=claims/load_date=YYYY-MM-DD/)
   --S3 event--> Lambda (validate file: name, size, header, row count vs trailer) --> Step Functions
       -> Glue job (CSV -> Parquet/Iceberg, partitioned by load_date)  -> Glue Data Catalog (tables)
       -> dbt on Athena (or Snowflake via external stage / Snowpipe)   -> bronze / silver / gold
       -> tests pass? publish : alert (SNS -> Slack/email) + quarantine
   consumers: Athena / Snowflake -> BI (QuickSight/Tableau/Sigma), APIs, AI agents
```
| Service | One line | Interview nugget |
|---|---|---|
| S3 | object storage, the lake | prefixes = partitions (`load_date=...`); lifecycle rules to Glacier; versioning on raw for audit |
| Glue Data Catalog | Hive-style metastore: table definitions over S3 | crawlers infer schemas, but in production you declare schemas (crawlers can drift) |
| Glue ETL | managed Spark | DPUs = cost; job bookmarks = built-in incremental |
| Athena | serverless SQL over S3 (Trino/Presto) | pay per TB scanned -> Parquet + partitions + column pruning cut cost 10-100x |
| Iceberg on S3 | table format: ACID, MERGE, time travel, schema evolution | makes incremental merge + snapshots possible on a lake; Athena and Snowflake both read it |
| Lambda | small event-driven functions (15 min max) | file arrival trigger, validation; not for heavy transforms |
| Step Functions | orchestration state machine | retries with backoff, catch -> alert, parallel feeds |
| EventBridge | event bus / schedules | cron-like schedules, cross-service events |
| IAM | who can do what | least privilege; separate roles for ingest, transform, read; no long-lived keys in CI (OIDC) |
| KMS | encryption keys | PHI: SSE-KMS at rest, TLS in transit, CloudTrail for audit |
| Lake Formation | fine-grained access on the lake | column/row-level security for PHI columns |
| CloudWatch | logs, metrics, alarms | alarm on failed runs, late files, row-count anomalies |
**Cost levers:** Parquet/columnar, partition pruning, compact small files, right-size Glue DPUs, Athena workgroup scan limits; in Snowflake: warehouse auto-suspend, right-size, clustering only when pruning is bad.
**HIPAA on AWS:** BAA with AWS, only HIPAA-eligible services, encryption everywhere, audit logs, minimum necessary (no names in gold, zip3).

### B6. Backfill runbook (the answer to "a feed was wrong for 2 weeks, what do you do?")
1. **Contain:** stop the schedule or mark the bad loads; tell consumers (which reports are affected).
2. **Scope:** which load dates, which models downstream (`dbt ls -s source:raw.claims+`).
3. **Fix the input:** get the corrected files, land them under new load dates (never overwrite raw: audit).
4. **Rebuild:** idempotent models make this a rerun: `--full-refresh` on the affected models, or a ranged backfill (vars / microbatch).
5. **Verify:** tie-outs, incremental = full-refresh comparison, compare before/after metrics (snapshot shows the restatement).
6. **Communicate + prevent:** restatement note to clients, add the test that would have caught it.

---

## Part C. 30-second answers (say them out loud)

**"Walk me through a pipeline you built."**
"I built a mini PBM warehouse on purposely dirty data: NCPDP-style claims with reversals and rebills, 834 eligibility, NPI and drug files. Bronze types the files, silver nets reversals, dedups, and quarantines bad rows, gold is a star schema with an SCD2 member dimension so every claim keeps the plan that was active on its date of service. On top of that I built PMPM, generic dispensing rate and a rebate reconciliation, and every layer ties out to the one before it in dollars, with 60+ tests and CI on every PR."

**"How do you make an incremental model correct, not just fast?"**
"Before I write any SQL I list every reason an old row can change. For claims that's new fills, late reversals, eligibility that shows up after the claim, and retro plan changes or terminations. Each reason gets its own trigger, and deletes get their own path. Then I prove it: the incremental result has to equal a full refresh. On my project that comparison showed zero differences after a load with 80 late reversals and 175 retro eligibility changes."

**"How do you test data pipelines?"**
"I think of it in layers. At the source I check freshness and row counts against the file manifest. Unit tests check the logic on a few hand-made rows. Data tests check grain, keys and accepted values on the real tables, and reconciliation tests tie dollars across layers. Contracts protect the tables other teams depend on. Severity is a decision: if the grain breaks or the money doesn't tie, the run stops; known noise gets a warning with a threshold and an owner."

**"Client says the September number changed. What happened?"**
"Claims restate: late reversals, rebills, retro eligibility. I snapshot the published mart, so I can show both versions with timestamps and which fills or members drove the change. In my project, CL001's September PMPM moved from $2,899.77 to $2,987.63 because 94 more September fills arrived late. It's also why the report carries an is_complete_month flag."

**"SCD2 vs snapshot?"**
"SCD2 is the modeling pattern: one row per version, with valid-from and valid-to. A dbt snapshot is one way to build it, and it records system time, meaning when we learned about a change. For claims I join on business time, meaning when the coverage was actually in effect, so I keep both clocks."

**"Something you found by testing?"**
Use the A4 bug story: a new feed pattern caused a surrogate-key collision, the unique test caught it before publish, and the fix went into silver.

**"Haven't used X."** Answer in this order: what I've done that's closest, how I'd approach it, and how I'd check that it worked.
