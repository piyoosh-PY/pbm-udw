# dbt reference: files, YAML keys, and what happens behind the scenes

Companion to Class 1. Examples come from this project (dbt Core 1.12, dbt-duckdb 1.11). The real SQL dbt executed is shown in section 8.

---

## 1. The short answer first: does dbt generate SQL from YAML?

**No, not for models.** Your model logic lives only in the `.sql` file (a single SELECT). YAML never becomes model SQL.

YAML does four other jobs:
1. **Describes** things (descriptions, owners, column docs) for `dbt docs`.
2. **Configures** things (materialization, schema, tags, contracts), the same settings you could put in `{{ config() }}`.
3. **Declares tests.** This is the one place dbt *does* write SQL for you: each generic test (`unique`, `not_null`, ...) is a macro that dbt renders into a SELECT returning the failing rows.
4. **Declares sources**: tables dbt reads but doesn't build.

dbt also writes the **wrapper SQL** around your SELECT (`create view ... as (...)`, `create table as`, `merge`), using the materialization macro for that model. See section 8.

---

## 2. Every file type in a dbt project

| File / folder | What it holds | Required? |
|---|---|---|
| `dbt_project.yml` | Project name, which profile to use, folder paths, vars, folder-level config defaults | Yes, one per project |
| `profiles.yml` | Connection: adapter type, database path or account, credentials (via `env_var`), threads | Yes (project folder or `~/.dbt/`) |
| `models/**/*.sql` | One model = one SELECT statement (+ optional Jinja and `{{ config() }}`) | Yes, at least one |
| `models/**/*.yml` | Properties: sources, model/column descriptions, tests, config | No, but always used in practice |
| `tests/*.sql` | Singular tests: a SELECT that returns failing rows | No |
| `macros/*.sql` | Reusable Jinja functions, custom generic tests, overrides (e.g. `generate_schema_name`) | No |
| `seeds/*.csv` | Small static CSVs loaded with `dbt seed` (code lookups, mappings) | No |
| `snapshots/*.yml` or `.sql` | SCD Type 2 history definitions (Class 3) | No |
| `analyses/*.sql` | SQL that compiles but never runs (ad-hoc analysis kept in git) | No |
| `packages.yml` / `dependencies.yml` | External packages (dbt_utils, dbt_expectations), installed with `dbt deps` | No |
| `target/` | Generated: compiled SQL, run SQL, `manifest.json`, `run_results.json`. Git-ignored | Generated |
| `logs/dbt.log` | Debug log of every statement sent to the database | Generated |

**YAML file names don't matter.** dbt reads every `.yml` under `models/`. The convention `_sources.yml`, `_bronze_models.yml` (leading underscore) keeps them at the top of the folder.

---

## 3. `dbt_project.yml`

```yaml
name: 'pbm_dbt'                 # required; letters, digits, underscores. Used in fqn and config paths below
version: '1.0.0'                # your project's version (free text)
config-version: 2               # optional in modern dbt (2 is the only value)
profile: 'pbm_dbt'              # which profile in profiles.yml to use
require-dbt-version: [">=1.10.0", "<2.0.0"]   # optional guard rail

model-paths: ["models"]         # where dbt looks for each resource type (these are the defaults)
seed-paths: ["seeds"]
test-paths: ["tests"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]
analysis-paths: ["analyses"]
target-path: "target"           # where compiled artifacts go
clean-targets: ["target", "dbt_packages"]   # what `dbt clean` deletes

vars:                           # project variables, read with {{ var('raw_root') }}; override with --vars
  raw_root: "../data/raw"

on-run-start: []                # SQL/macros run once before / after every invocation (e.g. grants, audit rows)
on-run-end: []

models:                         # folder-level config defaults. Keys mirror the folder path
  pbm_dbt:                      # must equal `name` above
    +materialized: view         # applies to every model in the project...
    bronze:                     # ...and is overridden for models/bronze/**
      +materialized: view
      +schema: bronze
    silver:
      +materialized: table
      +schema: silver
      +tags: ['silver']

seeds:
  pbm_dbt:
    +schema: reference
data_tests:
  pbm_dbt:
    +severity: error            # project-wide default for tests
```

**The `+` prefix** marks a *config* (as opposed to a folder name). `+schema: bronze` = "set schema for everything below"; `bronze:` without `+` = "the folder called bronze".

---

## 4. `profiles.yml`

```yaml
pbm_dbt:                        # profile name, must match `profile:` in dbt_project.yml
  target: dev                   # default output; switch with `dbt build --target prod`
  outputs:
    dev:
      type: duckdb              # adapter: duckdb | snowflake | redshift | bigquery | databricks | postgres | athena ...
      path: "{{ env_var('PBM_DUCKDB_PATH', '../warehouse/pbm_dev.duckdb') }}"   # duckdb: database file
      threads: 4                # how many models dbt builds in parallel
      # duckdb extras: extensions: [httpfs, parquet], settings: {s3_region: us-east-1}, attach: [...]
    prod:                       # same project, different target
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      password: "{{ env_var('SNOWFLAKE_PASSWORD') }}"   # never hard-code secrets
      role: TRANSFORMER
      warehouse: TRANSFORMING
      database: ANALYTICS
      schema: prod
      threads: 8
```

`target.schema`, `target.name` and `target.type` are available in Jinja. That's how one codebase behaves differently in dev and prod.

---

## 5. Source properties (`_sources.yml`)

```yaml
version: 2                              # optional in modern dbt; still common
sources:
  - name: raw                           # required. Referenced as source('raw', '<table>')
    description: Landing zone ...       # free text / markdown, shown in dbt docs
    database: pbm_dev                   # optional; defaults to target database
    schema: landing                     # optional; defaults to the source name. Ignored when external_location is used
    loader: generator.py                # optional, informational (e.g. fivetran, airbyte)
    config:
      enabled: true
      tags: ['pbm']
      meta: {owner: data-eng}           # free-form metadata
      external_location: "read_csv('{{ var('raw_root') }}/{name}/...')"   # dbt-duckdb: read files instead of a table
      freshness:                        # can be set here for all tables or per table
        warn_after: {count: 24, period: hour}    # period: minute | hour | day
        error_after: {count: 48, period: hour}
        filter: "load_date >= current_date - 7" # optional WHERE to limit the scan
    tables:
      - name: pharmacy_claims           # required. Second argument of source()
        identifier: claims_v2           # optional: physical name when it differs from `name`
        description: NCPDP-style transactions
        loaded_at_field: "cast(file_loaded_at as timestamp)"   # column/expression freshness compares to now()
        config:
          freshness: {warn_after: {count: 24, period: hour}}
        columns:
          - name: transaction_id
            description: Unique per transaction
            data_type: varchar          # documentation (and contracts on models)
            data_tests: [not_null]
```

**Freshness logic:** dbt runs `select max(<loaded_at_field>)` and compares it to the current time. Older than `warn_after` = WARN, older than `error_after` = ERROR STALE. It only runs with `dbt source freshness`, not with `dbt build`.

---

## 6. Model properties (`_bronze_models.yml`, `_silver_models.yml`, ...)

```yaml
version: 2
models:
  - name: stg_pharmacy_claims           # required; must match the .sql file name (without .sql)
    description: One row per transaction as received.
    config:                             # same keys as {{ config() }}; see the table below
      materialized: view
      tags: ['bronze', 'claims']
      meta: {owner: piyoosh, contains_phi: true}
      contract: {enforced: false}       # true = every column must declare data_type; build fails if the SELECT doesn't match
    constraints: []                     # model-level constraints (primary_key, foreign_key, check) with contracts
    data_tests:                         # model-level tests (span several columns)
      - dbt_utils.unique_combination_of_columns:      # (needs the dbt_utils package)
          arguments:
            combination_of_columns: [pharmacy_npi, rx_number, fill_number, date_of_service, transaction_code]
    columns:
      - name: transaction_id            # required within a column entry
        description: Transaction id from the claim processor
        data_type: varchar
        constraints: [{type: not_null}]
        quote: false                    # quote the column name in generated SQL
        meta: {pii: false}
        tags: ['key']
        data_tests:
          - not_null
          - unique:
              config:
                severity: warn          # warn | error (default error)
                error_if: ">100"        # thresholds; default "!=0"
                warn_if: "!=0"
                where: "_load_date = current_date"   # test only part of the data
                limit: 1000             # stop after N failures
                store_failures: true    # write failing rows to a table (<schema>_dbt_test__audit) for debugging
                tags: ['critical']
              name: unique_claim_txn    # optional custom test name
      - name: transaction_code
        data_tests:
          - accepted_values:
              arguments:                # test inputs (newer syntax; dbt v2 requires it)
                values: ['B1', 'B2', 'B3']
                quote: true
      - name: cardholder_id
        data_tests:
          - relationships:
              arguments:
                to: ref('stg_eligibility')
                field: cardholder_id
```

### Config keys you'll actually use (in YAML `config:`, in `{{ config() }}`, or with `+` in dbt_project.yml)

| Key | Meaning | Expected values |
|---|---|---|
| `materialized` | How the SELECT is persisted | `view`, `table`, `incremental`, `ephemeral`, `materialized_view` (adapter-dependent) |
| `schema` | Custom schema (combined with target schema by `generate_schema_name`) | string, e.g. `silver` → `main_silver` in our dev |
| `alias` | Physical table name if different from the file name | string |
| `database` | Write to another database | string |
| `tags` | Labels for selection: `dbt build -s tag:claims` | list of strings |
| `meta` | Free-form metadata (owner, PHI flag, SLA) | dict |
| `enabled` | Turn a model off without deleting it | `true` / `false` |
| `unique_key` | Incremental: key used to update existing rows | column or list of columns |
| `incremental_strategy` | How new rows are applied | `append`, `merge`, `delete+insert`, `insert_overwrite`, `microbatch` (depends on adapter) |
| `on_schema_change` | Incremental: what to do when columns change | `ignore` (default), `fail`, `append_new_columns`, `sync_all_columns` |
| `full_refresh` | Allow / forbid `--full-refresh` on this model | `true`, `false`, unset |
| `contract` | Enforce column names and types | `{enforced: true}` |
| `persist_docs` | Push descriptions into the warehouse as comments | `{relation: true, columns: true}` |
| `grants` | Grant privileges after build | `{select: ['analyst_role']}` |
| `pre-hook` / `post-hook` | SQL run before / after the model | string or list of SQL |
| `access` | Who may `ref()` this model across groups | `private`, `protected` (default), `public` |
| `docs` | Show / hide in docs, node color | `{show: true, node_color: '#1F3864'}` |

**Precedence (most specific wins):** `{{ config() }}` in the .sql file → `config:` in the model's YAML → `+key` in `dbt_project.yml` → dbt default.

---

## 7. A model `.sql` file

```sql
{{ config(materialized='view', tags=['bronze']) }}   -- optional; overrides YAML and dbt_project.yml

with src as (
    select * from {{ source('raw', 'pharmacy_claims') }}   -- external data
)

select ...
from src
-- no trailing semicolon: dbt wraps this SELECT inside other SQL
```

Rules: **exactly one SELECT** (CTEs allowed), **no DDL**, file name = model name = default table/view name.

Jinja you'll use most:

| Jinja | Meaning |
|---|---|
| `{{ ref('model') }}` | Another model: adds a DAG edge and resolves the environment-specific name |
| `{{ source('src', 'table') }}` | A source table: lineage + freshness |
| `{{ var('raw_root') }}` | Project variable (override: `--vars '{raw_root: s3://...}'`) |
| `{{ env_var('NAME', 'default') }}` | Environment variable (secrets, paths) |
| `{{ this }}` | The relation this model is building (used in incremental filters) |
| `{% if is_incremental() %}` | True on incremental runs when the table already exists |
| `{{ target.name }}` / `{{ target.schema }}` | Current environment |
| `{% macro ... %}` / `{{ my_macro(col) }}` | Reusable SQL (Class 2: `normalize_ndc`) |

---

## 8. What happens when you run `dbt build`

```
1. LOAD     read dbt_project.yml + profiles.yml, connect to the adapter (duckdb)
2. PARSE    read every .sql and .yml; render Jinja in "parse mode" to capture ref(), source(), config()
            -> builds the graph of nodes (models, tests, sources, seeds, snapshots)
            -> writes target/manifest.json  (cached in partial_parse.msgpack so the next parse is fast)
3. SELECT   apply --select / --exclude; order nodes by the DAG (sources -> stg_ -> int_ -> marts, tests after their model)
4. EXECUTE  for each node, up to `threads` at a time:
     a. COMPILE   render Jinja fully: ref/source become real names   -> target/compiled/...
     b. WRAP      the materialization macro adds the DDL             -> target/run/...
     c. RUN       send SQL to the database, inside a transaction
     d. TEST      tests on that model run next; a failing ERROR-severity test SKIPS everything downstream
5. ARTIFACTS target/run_results.json (status, timing, rows affected per node), manifest.json (whole project)
             also: catalog.json (from `dbt docs generate`), sources.json (from `dbt source freshness`)
```

### Real example from our project: `stg_rebates`

**You wrote** (`models/bronze/stg_rebates.sql`):
```sql
select trim(rebate_quarter) as rebate_quarter, ...
from {{ source('raw', 'rebates') }}
```

**Compiled** (`target/compiled/.../stg_rebates.sql`): Jinja resolved, nothing else added:
```sql
select trim(rebate_quarter) as rebate_quarter, ...
from read_csv('../data/raw/rebates/load_date=*/*.csv', all_varchar=true, hive_partitioning=true, filename=true)
```

**Run** (`target/run/.../stg_rebates.sql`) and the log. The *view* materialization does an **atomic swap**, so readers never see a half-built object:
```sql
create schema if not exists "pbm_dev"."main_bronze";
create view "pbm_dev"."main_bronze"."stg_rebates__dbt_tmp" as ( <compiled SELECT> );   -- 1. build new under a temp name
alter view "pbm_dev"."main_bronze"."stg_rebates" rename to "stg_rebates__dbt_backup"; -- 2. move old out of the way
alter view "pbm_dev"."main_bronze"."stg_rebates__dbt_tmp" rename to "stg_rebates";    -- 3. promote new
commit;
drop view if exists "pbm_dev"."main_bronze"."stg_rebates__dbt_backup" cascade;         -- 4. clean up
```
A **table** materialization is the same idea with `create table ... as`. An **incremental** model runs `insert` / `merge` / `delete+insert` into the existing table instead (Class 3).

### Real example: what a YAML test turns into
You wrote three lines of YAML:
```yaml
- unique:
    config: {severity: warn}
```
dbt rendered the `unique` test macro into this SELECT (failing rows = duplicated values):
```sql
select transaction_id as unique_field, count(*) as n_records
from "pbm_dev"."main_bronze"."stg_pharmacy_claims"
where transaction_id is not null
group by transaction_id
having count(*) > 1
```
...and wrapped it to decide pass / warn / error:
```sql
select count(*) as failures,
       count(*) != 0 as should_warn,
       count(*) != 0 as should_error
from ( <the SELECT above> ) dbt_internal_test
```
`failures` = number of **duplicated values (groups)**, not rows. With one load you'll see **WARN 150** (150 transaction ids appear twice). (In class I said 300 = rows; that was wrong. My dry run had two loads, so 300 groups.)

`accepted_values` becomes:
```sql
with all_values as (
    select response_status as value_field, count(*) as n_records
    from "pbm_dev"."main_bronze"."stg_pharmacy_claims"
    group by response_status
)
select * from all_values where value_field not in ('P', 'R')
```

A **singular test** (`tests/*.sql`) skips the macro step: your SELECT is used as written, then wrapped the same way.

### What's inside `manifest.json` (one node)
```json
"model.pbm_dbt.stg_rebates": {
  "resource_type": "model",
  "schema": "main_bronze", "alias": "stg_rebates",
  "fqn": ["pbm_dbt", "bronze", "stg_rebates"],
  "depends_on": {"nodes": ["source.pbm_dbt.raw.rebates"]},
  "config": {"materialized": "view", "schema": "bronze", "on_schema_change": "ignore", "contract": {"enforced": false}, ...}
}
```
The manifest is the whole project as data. CI (`state:modified+`), dbt docs, lineage tools and AI agents all read it.

---

## 9. Commands to explore what dbt does

| Command | What it shows / does |
|---|---|
| `dbt parse` | Parse only; catches YAML/Jinja errors fast |
| `dbt compile -s stg_rebates` | Writes compiled SQL to target/compiled without running it |
| `dbt show -s stg_pharmacy_claims --limit 5` | Runs the model's SELECT and prints rows (no table built) |
| `dbt ls -s +stg_pharmacy_claims+` | Lists the model with its upstream (+ before) and downstream (+ after) |
| `dbt run -s bronze` / `dbt test -s bronze` | Build or test one folder |
| `dbt build -s tag:claims` | Build + test by tag |
| `dbt build --full-refresh` | Rebuild incremental models from scratch |
| `dbt retry` | Rerun only what failed last time |
| `dbt docs generate && dbt docs serve` | Docs site with the lineage graph |
| `dbt --debug build` | Prints every SQL statement (what you see in logs/dbt.log) |
| `dbt clean` | Deletes target/ and dbt_packages/ |

Try now: `dbt compile -s stg_rebates`, then open `target/compiled/pbm_dbt/models/bronze/stg_rebates.sql` and `target/run/pbm_dbt/models/bronze/stg_rebates.sql` side by side.
