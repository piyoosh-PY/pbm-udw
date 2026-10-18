# dbt materializations, the DAG, nodes, tests and commands

Companion to `dbt-execution-order-and-naming.md` (parse vs execute, how ref/source/macros resolve, naming rules).
This note covers: what "materialization" means, every option with the real SQL dbt ran in our project,
our project's DAG and node types, how tests attach to nodes, and the full command cheat sheet.

---

## 1. What "materialization" means

You only ever write a **SELECT**. The materialization decides **what dbt builds from that SELECT in the warehouse**:
a view, a table, an incremental table, nothing at all (ephemeral), and so on.

```
your model file:  select ... from {{ ref('x') }}
                         │
         materialization macro wraps it in DDL/DML
                         │
warehouse:   create view ... as (select ...)        <- view
             create table ... as (select ...)       <- table
             merge into ... using (select ...)      <- incremental
             (nothing; pasted into the next model)  <- ephemeral
```

Each materialization is itself a **macro** (`materialization_table_duckdb`, `materialization_incremental_duckdb`, ...).
That's why adapters can implement them differently, and why you can even write your own.

Set it (most specific wins):
```sql
{{ config(materialized='incremental') }}               -- 1. in the model file
```
```yaml
models:                                                 # 2. in the model's .yml entry (config:)
  - name: int_pharmacy_fills
    config: {materialized: incremental}
```
```yaml
models:                                                 # 3. by folder in dbt_project.yml
  pbm_dbt:
    bronze: {+materialized: view}
    silver: {+materialized: table}
```
Default if nothing is set: `view`.

---

## 2. The options, with the SQL dbt actually ran (from `target/run/`)

### `view`: a saved query, no data stored
```sql
create view "pbm_dev"."main_bronze"."stg_rebates__dbt_tmp" as (
    select trim(rebate_quarter) as rebate_quarter, ...
    from read_csv('../data/raw/rebates/load_date=*/*.csv', all_varchar=true, ...)
);
-- then: rename old view -> __dbt_backup, rename __dbt_tmp -> stg_rebates, drop backup
```
- Cheap to build (milliseconds), always fresh, costs compute **every time someone queries it**.
- Ours: all bronze `stg_` models. A new file in `data/raw` is visible immediately, with no rebuild.

### `table`: run the query once, store the result
```sql
create table "pbm_dev"."main_silver"."int_drugs__dbt_tmp" as (
    select ndc11, drug_name, ... from "pbm_dev"."main_bronze"."stg_drug_reference"
    qualify row_number() over (partition by ndc11 order by _load_date desc) = 1
);
-- then the same atomic swap: old -> __dbt_backup, __dbt_tmp -> int_drugs, drop backup
```
- Fast to query, but rebuilt **from scratch every run** (cost grows with all history).
- Ours: `int_drugs`, `int_providers`, `int_eligibility`, `int_pharmacy_claims__quarantine`, `int_member_coverage_spans`.
- The tmp + swap means readers never see a half-built table: if the build fails, the old table stays.

### `incremental`: build once, then only add or change rows
First run (or `--full-refresh`): exactly like `table`. Later runs: dbt builds the batch (your SELECT with the
`{% if is_incremental() %}` filter) into a temp table, then applies the **strategy**:

**`append`** (`toy_2_append`):
```sql
insert into "main_playground"."toy_2_append" ("order_id", "customer", "status", "amount", "updated_at")
    (select "order_id", ... from "toy_2_append__dbt_tmp20261017...");
```
**`merge`** (`toy_3_merge`, `int_pharmacy_claims__typed`):
```sql
MERGE INTO "main_playground"."toy_3_merge" AS DBT_INTERNAL_DEST
USING "toy_3_merge__dbt_tmp20261017..." AS DBT_INTERNAL_SOURCE
ON (DBT_INTERNAL_SOURCE.order_id = DBT_INTERNAL_DEST.order_id)     -- unique_key
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME;
```
**`delete+insert`** (`int_pharmacy_fills`):
```sql
delete from "main_silver"."int_pharmacy_fills"
where (fill_key) in (select (fill_key) from "int_pharmacy_fills__dbt_tmp20261017...");   -- only keys IN the batch
insert into "main_silver"."int_pharmacy_fills" (...) (select ... from "int_pharmacy_fills__dbt_tmp20261017...");
```
Read those two closely: both statements only touch keys that are **in the batch**. That's the whole reason
deletes by absence are invisible (toy Day 3, PBM Fill A), and why we use tombstones.

Other strategies: `insert_overwrite` (replace whole partitions: Athena, BigQuery, Spark) and `microbatch`
(dbt runs one batch per time period from `event_time`; good for backfills).

Incremental-only configs: `unique_key`, `incremental_strategy`, `on_schema_change`
(`ignore` default / `fail` / `append_new_columns` / `sync_all_columns`), `incremental_predicates`.

### `ephemeral`: nothing is built; the SQL is pasted into whoever refs it
Verified on our project: a model `eph_double` with `materialized='ephemeral'`, referenced by `uses_eph`, compiles to:
```sql
with __dbt__cte__eph_double as (
    select order_id, amount * 2 as double_amount from "pbm_dev"."main_playground"."toy_orders"
) select * from __dbt__cte__eph_double where double_amount > 100
```
- No object in the warehouse, so it can't be queried directly or tested on its own, and it's harder to debug.
- Use for small reusable steps you never want to expose. Most teams prefer a view.

### `materialized_view` / dynamic tables
The warehouse keeps the result refreshed by itself (Snowflake dynamic tables, BigQuery and Postgres materialized
views, Databricks). DuckDB doesn't have them, so we can't use it here. Know the trade-off: less pipeline code,
less control over when it refreshes and what it costs.

### Not "materializations" but built resources
| Resource | What dbt builds | Command |
|---|---|---|
| **seed** (`seeds/*.csv`) | a table loaded from the CSV (dropped and reloaded each run) | `dbt seed` |
| **snapshot** (`snapshots/*.yml`) | an SCD2 table, merged each run; never dropped, can't be rebuilt | `dbt snapshot` |
| **test** | nothing permanent: a SELECT that must return 0 rows (unless `store_failures`) | `dbt test` |
| **analysis** | nothing: compiled only | `dbt compile` / `dbt show` |

### Choosing one
| | view | table | incremental | ephemeral |
|---|---|---|---|---|
| Build cost | ~0 | all rows, every run | new rows only | 0 |
| Query speed | slow (recomputes) | fast | fast | n/a |
| Freshness | always live | as of last run | as of last run | n/a |
| Complexity | low | low | **high** (late data, deletes, schema changes) | low, but hard to debug |
| Our use | bronze staging | silver reference + small models | claims, fills | — |

Rule of thumb: **view → table → incremental**, moving right only when the cost forces you.

---

## 3. Our project's DAG (nodes and edges)

**Node** = anything dbt knows about: source, model, seed, snapshot, test, analysis.
**Edge** = a `ref()` or `source()` inside a node. Our project has 16 models, 1 seed, 2 snapshots,
28 tests, 2 analyses and 5 sources. `dbt build` runs 47 of them (sources and analyses don't "run").

```
SOURCES (files)          BRONZE (view)              SILVER (table / incremental / snapshot)
---------------          -------------              ---------------------------------------
raw.drug_reference  ──>  stg_drug_reference  ──>  int_drugs (table) ─────────────────────────┐
raw.providers       ──>  stg_providers       ──>  int_providers (table)                       │
raw.eligibility     ──>  stg_eligibility     ──>  int_eligibility (table) ──┬─────────────────┤
                                                                            │                 │
                                                    snap_member_eligibility (snapshot)        │
                                                                            │                 │
                                                    int_member_coverage_spans (table)         │
raw.pharmacy_claims ──>  stg_pharmacy_claims ───────────────────────────────┴─> int_pharmacy_claims__typed (incremental, merge)
raw.rebates         ──>  stg_rebates                                               │                │
                                                         int_pharmacy_claims__quarantine (table)   int_pharmacy_fills (incremental, delete+insert)

PLAYGROUND:  toy_orders (seed) ──> toy_1_full / toy_2_append / toy_3_merge / toy_4_merge_lookback ; toy_orders_snapshot
```

**Order:** a node starts as soon as all its parents finish, up to `threads: 4` at once. The four independent
bronze views run together first, then whatever they unblock. The `N of 47` in the log is the node's position in
the plan, not the order it finished.

See it yourself:
```bash
dbt ls -s +int_pharmacy_fills                 # everything upstream of fills
dbt ls -s int_eligibility+                    # everything downstream of eligibility
dbt ls --resource-type test -s int_pharmacy_fills    # tests attached to fills
dbt docs generate && dbt docs serve           # clickable lineage graph in the browser
```

---

## 4. How tests relate to nodes

A test is its own node with an edge **from** the thing it tests:

| Test | Defined in | Depends on | Runs when |
|---|---|---|---|
| `unique_int_pharmacy_fills_fill_key` (generic) | `_silver_models.yml` under fills | `int_pharmacy_fills` | right after fills builds |
| `relationships_int_pharmacy_fills_member_key...` | `_silver_models.yml` | fills **and** `int_eligibility` | after both exist |
| `source_not_null_raw_pharmacy_claims_transaction_id` | `_sources.yml` | the source | before staging (also with `dbt test -s source:raw`) |
| `assert_fills_incremental_matches_full_recompute` (singular) | `tests/*.sql` | every model it `ref`s: typed, fills | after both |
| `assert_silver_handles_every_claims_defect` | `tests/*.sql` | bronze, typed, fills | after all three |

**In `dbt build`:** each node's tests run right after it. If a test with `severity: error` fails, every node
**downstream of the tested node is SKIPPED**, so bad data doesn't flow into gold. `severity: warn` reports and
continues: our bronze `unique` (WARN 450) and the orphan `relationships` (WARN 100).

**In `dbt run` then `dbt test`:** all models build first, tests run after, and nothing is skipped. That's why
`build` is the safer default.

The "test count" check: when `TOTAL` drops unexpectedly (Class 2: 34 → 31), a test lost its edge, for example
because a YAML `- name:` doesn't match any model.

---

## 5. What happens to one node, step by step (`dbt build`)
| # | Step | Where to look |
|---|---|---|
| 1 | Parse: read the file, record `ref`s (the DAG edge), capture `config()` | `target/manifest.json` |
| 2 | Wait until all parents finish | log order |
| 3 | Compile: Jinja to SQL with real relation names for the current target | `target/compiled/...` |
| 4 | Pre-hooks | — |
| 5 | Materialization macro wraps the SELECT (create/merge/delete+insert, tmp + swap) | `target/run/...` |
| 6 | Post-hooks (grants, etc.) | — |
| 7 | Record status, timing, rows | `target/run_results.json` |
| 8 | Run this node's tests; on an error-severity failure, skip children | log |

---

## 6. Command cheat sheet
### Setup and checks
| Command | Does |
|---|---|
| `dbt init <name>` | create a project skeleton |
| `dbt debug` | check profiles.yml, the connection and the project |
| `dbt deps` | install packages from packages.yml into `dbt_packages/` |
| `dbt parse` | parse only; writes manifest.json (catches YAML/ref errors fast) |
| `dbt clean` | delete `target/` and `dbt_packages/` |

### Building
| Command | Does |
|---|---|
| `dbt build` | seeds + models + snapshots + tests in DAG order, tests right after each node |
| `dbt run` | models only |
| `dbt test` | tests only (tables must already exist) |
| `dbt seed` | load `seeds/*.csv` |
| `dbt snapshot` | run snapshots |
| `dbt build --full-refresh` | rebuild incremental models and seeds from scratch (snapshots are never dropped) |
| `dbt retry` | re-run only what failed or was skipped in the last invocation |
| `dbt source freshness` | check `loaded_at_field` against warn/error thresholds |
| `dbt run-operation <macro> --args '{...}'` | run a macro by itself (admin tasks, grants, cleanup) |
| `dbt clone --state <dir>` | zero-copy clone of prod objects into dev (on warehouses that support it) |

### Looking
| Command | Does |
|---|---|
| `dbt compile -s x` | write compiled SQL to `target/compiled` |
| `dbt show -s x` / `dbt show --inline "select ..."` | run a query and preview rows (models, analyses, tests) |
| `dbt ls -s <selector>` | list matching nodes without running them |
| `dbt docs generate` / `dbt docs serve` | build and serve the documentation site and lineage graph |

### Selectors (work with build, run, test, ls, compile)
| Selector | Picks |
|---|---|
| `-s int_pharmacy_fills` | one node (plus its tests, in build) |
| `-s +int_pharmacy_fills` | it and all parents |
| `-s int_eligibility+` | it and all children |
| `-s +int_pharmacy_fills+` | full lineage both ways |
| `-s path:models/silver` or `-s silver` | a folder |
| `-s tag:playground` | a tag (our toy lab) |
| `-s source:raw+` | everything fed by a source |
| `-s config.materialized:incremental` | every incremental model |
| `-s resource_type:snapshot` | every snapshot |
| `-s test_type:singular` | only singular tests |
| `-s state:modified+ --state <prod artifacts>` | only changed nodes plus downstream (Slim CI, Class 5) |
| `--exclude <selector>` | everything except |

Useful flags: `--target prod`, `--vars '{raw_root: s3://...}'`, `--threads 8`, `--fail-fast` (stop at the first
failure), `--warn-error-options '{"error": ["NoNodeForYamlKey"]}'`, `--debug`.

---

## 7. Interview answer (30 seconds)
"A materialization decides what dbt builds from a model's SELECT. Views are free to build but recompute on every
query, so I use them for staging. Tables are rebuilt every run, for reference data and anything I can afford to
recompute. Incremental models process only new data with merge, delete+insert or partition overwrite, and I only
move to them when cost forces it, because I then have to handle late data, deletes and schema changes, and prove
incremental equals full refresh with a test. Ephemeral models are inlined as CTEs. Snapshots give SCD2 history.
dbt runs all of it as a DAG built from `ref()`. In `dbt build` each node's tests run right after it, and an
error-level failure skips everything downstream."
