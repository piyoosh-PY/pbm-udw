# dbt: order of execution, how references resolve, and naming rules

Companion to `dbt-reference.md` (which covers YAML keys and config). This note answers:
1. In what order does dbt read files and run things?
2. How do `ref`, `source`, macros, tests and analyses get wired together?
3. Do test files have to start with `assert_`?
4. Which names does dbt enforce, and which are only conventions?

Everything marked **(verified)** was tested on our project with dbt 1.12.6 + dbt-duckdb.

---

## Part 1. The big picture: dbt runs in two phases

```
PHASE A: PARSE (read everything, run nothing)       PHASE B: EXECUTE (talk to the warehouse)
------------------------------------------------    ------------------------------------------
1. find dbt_project.yml                             7. on-run-start hooks
2. read profiles.yml, pick target                   8. walk the DAG in dependency order:
3. load packages (dbt_packages/)                       for each node: compile -> pre-hook ->
4. load ALL macros                                      materialization -> post-hook
5. read every resource file (.sql, .csv, .yml, .md)    (tests run right after their parent in `build`)
6. build the DAG, validate, write manifest.json      9. on-run-end hooks
                                                    10. write run_results.json
```

The key idea: **dbt reads the whole project before it runs anything.** File order on disk doesn't matter. Execution order comes only from the dependency graph (DAG) that `ref()` and `source()` build. You never tell dbt "run A then B"; you write `ref('A')` inside B and dbt works it out.

---

## Part 2. Phase A, step by step: what gets read first

### Step 1. Find the project
dbt looks for `dbt_project.yml` in the current directory (or `--project-dir`). That's why you `cd pbm_dbt` before running commands. From this file it learns:
- `name: pbm_dbt` (the package name, used in node IDs like `model.pbm_dbt.int_drugs`)
- `profile: pbm_dbt` (which profile to use)
- the paths: `model-paths`, `macro-paths`, `test-paths`, `seed-paths`, `snapshot-paths`, `analysis-paths`, `docs-paths`
- `vars` (our `raw_root`) and folder-level configs (`+materialized`, `+schema`)

### Step 2. Find the connection
dbt looks for `profiles.yml` in this order, and the first match wins:
1. `--profiles-dir` flag
2. `DBT_PROFILES_DIR` environment variable
3. the current directory (that's why ours sits inside `pbm_dbt/`)
4. `~/.dbt/profiles.yml`

It picks the profile named in `dbt_project.yml` and the `target` (default `dev`, override with `--target prod`). This is where `env_var('PBM_DUCKDB_PATH', ...)` is resolved.

### Step 3. Load packages
If `packages.yml` / `dependencies.yml` lists packages (for example `dbt_utils`), `dbt deps` downloads them into `dbt_packages/`. At parse time each package is loaded as a separate project with its own models and macros. (We have none yet; we'll add `dbt_utils` later.)

### Step 4. Load ALL macros, before any model
Macros load first because models, tests and YAML all call them. dbt loads:
- **built-in dbt macros** (`ref`, `source`, `config`, `is_incremental`, materializations like `table`/`view`/`incremental`, the generic tests `not_null`/`unique`/...)
- **adapter macros** (dbt-duckdb's versions of `create_table_as` and so on)
- **package macros**
- **your macros** (`macros/cleaning.sql`)

On our project dbt reports **505 macros (verified)** even though we wrote five. Nearly everything dbt does is a macro you can read and override.

**Override rule (which macro wins when names clash):**
1. **your root project** wins over
2. installed packages, which win over
3. the adapter-specific version (`duckdb__create_table_as`), which wins over
4. dbt's default (`default__create_table_as`)

That's how you'd customize schema naming: we use dbt's built-in `generate_schema_name` (target schema `main` + custom `silver` = `main_silver`). If you put a macro with the same name in `macros/`, yours wins, and that's the standard way teams make prod write to plain `silver` while dev writes to `dbt_piyoosh_silver`. dbt picks the adapter version through `adapter.dispatch()`, which is why many built-ins come in `default__x` / `duckdb__x` / `snowflake__x` variants.

### Step 5. Read every resource file
dbt walks each configured path and creates one **node** per resource:

| Folder (default) | File types | Becomes |
|---|---|---|
| `models/` | `.sql`, `.py` | model nodes |
| `models/` (and others) | `.yml` | properties attached ("patched") to nodes; sources; generic test nodes |
| `seeds/` | `.csv` | seed nodes (loaded with `dbt seed`) |
| `snapshots/` | `.sql` or YAML | snapshot nodes (SCD2; Class 3) |
| `tests/` | `.sql` | singular test nodes |
| `tests/generic/` or `macros/` | `{% test %}` blocks | generic test *definitions* (templates, not nodes) |
| `analyses/` | `.sql` | analysis nodes: compiled, never run |
| `macros/` | `.sql` | macros (already loaded in step 4) |
| any docs path | `.md` with `{% docs %}` | doc blocks referenced from descriptions |

For each `.sql` model dbt **renders the Jinja once at parse time** with `execute = False`. During this pass `ref()` and `source()` don't return table names yet; they only **record dependencies**. `config()` calls are captured too.

This is why the `execute` variable exists: anything that queries the database inside Jinja (like `run_query`) must be wrapped in `{% if execute %}`, because at parse time there's no connection to use.

### Step 6. Patch YAML, generate tests, build the DAG
- **Patching:** each entry in a `.yml` file (`- name: int_pharmacy_fills`) is matched by name to a node, and its description, columns, config and tests are attached. If no node matches, dbt only *warns*: "Did not find matching node for patch". That's exactly how your `int_pharmacy_claims__types` typo silently dropped 3 tests.
- **Generic tests become nodes:** every `data_tests:` entry is turned into its own test node with a generated name (Part 5).
- **Validation:** duplicate names are a hard error (Part 6), `ref()` to a missing model is a hard error, and a cycle (A refs B, B refs A) is a hard error.
- **Artifacts:** `target/manifest.json` (every node, its compiled-ready SQL, config, dependencies) and `target/partial_parse.msgpack` (a cache, so the next parse only re-reads changed files).

**Config precedence** is resolved here. Most specific wins:
1. `{{ config(...) }}` inside the `.sql` file
2. `config:` in the model's `.yml` entry
3. `dbt_project.yml`, deepest matching folder first (`models: pbm_dbt: silver:` beats `models: pbm_dbt:`)
4. dbt defaults (`view`, target schema)

---

## Part 3. Phase B: what actually runs, and in what order

### The DAG decides the order
From our project:
```
source raw.pharmacy_claims ─> stg_pharmacy_claims ─┐
source raw.drug_reference ──> stg_drug_reference ──> int_drugs ───────┐
source raw.eligibility ─────> stg_eligibility ─────> int_eligibility ─┼─> int_pharmacy_claims__typed ─┬─> int_pharmacy_claims__quarantine
                                                                      │                              └─> int_pharmacy_fills
```
dbt runs a node as soon as **all its parents are done**, up to `threads: 4` at once. That's why the build log printed `1 of 31` through `4 of 31` together (the four independent bronze views), and why line numbers in the log look out of order: the number is the node's position in the plan, not the time it finished.

See the graph yourself:
```bash
dbt ls -s +int_pharmacy_fills --resource-type model     # everything upstream (verified)
dbt ls -s int_eligibility+                              # everything downstream
dbt docs generate && dbt docs serve                     # visual lineage graph in the browser
```

### What happens to ONE model node
1. **Compile:** render the Jinja again, now with `execute = True`. `ref('int_drugs')` becomes `"pbm_dev"."main_silver"."int_drugs"`. Output goes to `target/compiled/...`.
2. **Pre-hooks** (if configured).
3. **Materialization macro:** the `table`/`view`/`incremental` macro wraps your SELECT in DDL (create into `__dbt_tmp`, rename the old one to `__dbt_backup`, swap, drop). Output goes to `target/run/...`. This is the SQL actually sent to DuckDB.
4. **Post-hooks** (grants, for example).
5. A result is recorded in `run_results.json` (status, timing, rows affected).

### `dbt run` vs `dbt test` vs `dbt build`
| Command | Runs | Order |
|---|---|---|
| `dbt run` | models only | DAG order |
| `dbt test` | tests only (against tables that must already exist) | any order |
| `dbt seed` / `dbt snapshot` | seeds / snapshots | — |
| `dbt build` | seeds + models + snapshots + tests (+ unit tests) | **DAG order, with each node's tests run right after it** |

`build` is what we use, because of this rule: **if a node's test fails with severity `error`, every downstream node is SKIPPED.** Bad data doesn't flow into gold. Severity `warn` reports the problem and lets the run continue, which is why our bronze `unique` (WARN 150) didn't block silver.

Unit tests (Class 5) run *before* their model in `build`: they test the logic on fake input before real data is built.

### Hooks order around the whole run
```
on-run-start (dbt_project.yml)
  -> [per node] pre-hook -> materialize -> post-hook
on-run-end (dbt_project.yml)   # e.g. grant select on all schemas, log run to an audit table
```

---

## Part 4. How each kind of reference resolves

### `ref('model_name')`
- **At parse:** records an edge in the DAG (this model depends on `model_name`).
- **At compile:** returns the full relation `database.schema.identifier` for the **current target**. The same code points at dev in dev and prod in prod. This is the main reason never to hard-code table names.
- Two-argument form: `ref('dbt_utils', 'some_model')` refers to a model in another package.
- Works for models, seeds and snapshots (anything that builds a relation). It does **not** work for tests or analyses; nothing can depend on those.
- Lookup is by **name only, not folder**. That's why model names must be unique project-wide (Part 6).

### `source('raw', 'pharmacy_claims')`
- Points to data dbt didn't build (the raw files). Declared in `_sources.yml`.
- Resolves to `database.schema.identifier` from the source YAML, or, as in our project, to the `external_location` expression (`read_csv(...)`).
- Adds a source node to the DAG, so `dbt source freshness` and the lineage graph know about it.
- Rule: only bronze (`stg_`) models call `source()`. Everything else calls `ref()`.

### Macros: `{{ normalize_ndc('ndc_raw') }}`
- **Not nodes, not in the DAG.** A macro is a text template: dbt pastes its output into the SQL at compile time. Check `target/compiled/.../int_pharmacy_claims__typed.sql` and you'll see the full `case when regexp_full_match...` expression where you wrote one macro call.
- Called by name from anywhere: models, tests, other macros, hooks, even YAML (`external_location` used `var()`).
- Package macros are called with a prefix: `{{ dbt_utils.generate_surrogate_key([...]) }}`.

### Tests: how a YAML test finds its model
```yaml
  - name: int_pharmacy_fills          # 1. matched to the model node by name
    columns:
      - name: fill_key
        data_tests: [unique]           # 2. dbt finds the generic test definition named `unique`
```
dbt then calls the `unique` test macro with `model = ref('int_pharmacy_fills')` and `column_name = 'fill_key'`, renders it into a SELECT that returns the bad rows, and makes that a test node that **depends on** the model. **A test passes when its query returns zero rows.** With severity `warn`, rows returned means WARN; with `error`, it means FAIL.

Singular tests (`tests/*.sql`) reference models with `ref()` like any model, and that `ref()` is what links them in the DAG. Our `assert_silver_handles_every_claims_defect` refs bronze, typed and fills, so it runs after all three.

### Analyses
`analyses/macro_check.sql` is compiled (Jinja, refs and macros all resolve) but **never executed** by `run` or `build`. It's for scratch SQL, ad hoc reports and audits you want version-controlled and environment-aware. Run the compiled SQL yourself, or use `dbt show -s macro_check`.

### `var()` and `env_var()`
- `var('raw_root')` comes from `vars:` in `dbt_project.yml`, overridable per run: `dbt build --vars '{raw_root: s3://bucket/raw}'`. (We'll use that in Class 6.)
- `env_var('PBM_DUCKDB_PATH', 'default')` reads the OS environment. Use it for secrets and paths that differ by machine; never commit secrets.

---

## Part 5. Tests in detail: do they need to start with `assert_`?

**No.** dbt doesn't care what a singular test file is called. **(verified)** A file `tests/no_negative_plan_paid.sql` containing
```sql
select * from {{ ref('int_pharmacy_fills') }} where plan_paid_amount < 0
```
was picked up as test `pbm_dbt.no_negative_plan_paid`. The rules that actually apply:
- It must be a `.sql` file somewhere under `test-paths` (default `tests/`; subfolders are fine).
- It must be a single SELECT that returns the **failing rows**. Zero rows is a pass.
- Its name (the file name) must be unique among tests.

`assert_` is a **team convention**: the name reads as the business rule that must hold ("assert claims reconcile bronze to silver"). Keep using it, because it makes logs readable.

### The three kinds of tests
| Kind | Where | Name | Example |
|---|---|---|---|
| **Generic** (reusable, takes arguments) | definition in `tests/generic/*.sql` or `macros/*.sql` as `{% test name(model, column_name) %}`; used in YAML | the `{% test %}` block name is what you write in YAML | `not_null`, `unique`, `accepted_values`, `relationships`, or your own `is_positive` |
| **Singular** (one-off SQL) | `tests/*.sql` | the file name | `assert_claims_reconcile_bronze_to_silver` |
| **Unit** (logic on mock rows; dbt 1.8+) | `unit_tests:` in a `.yml` | the `name:` you give it | Class 5 |

Your own generic test (verified it parses):
```sql
-- tests/generic/test_is_positive.sql
{% test is_positive(model, column_name) %}
select * from {{ model }} where {{ column_name }} <= 0
{% endtest %}
```
```yaml
      - name: plan_paid_amount
        data_tests: [is_positive]
```
Strict parts: the block must be `{% test <name>(model, ...) %}` ... `{% endtest %}`, the first argument is `model`, and `column_name` is filled in automatically when the test sits under a column. The *file* name doesn't matter; the *block* name is what YAML uses.

### Auto-generated names for generic tests
dbt builds the name as `<test>_<model>_<column>[_<args>]`:
- `unique_int_pharmacy_fills_fill_key`
- `accepted_values_stg_pharmacy_claims_transaction_code__B1__B2__B3`
- `source_not_null_raw_pharmacy_claims_transaction_id` (source tests get a `source_` prefix)
- names that get too long are truncated and given a hash: `relationships_int_pharmacy_fil_d29e677c76d68b924fb8f18fc22d6c6b`

You can set your own with `name:` under the test. Useful when you want to `dbt test -s` one specific test.

### Test configs worth knowing
```yaml
data_tests:
  - unique:
      config:
        severity: warn          # warn | error
        error_if: ">100"        # fail only above a threshold
        warn_if: ">0"
        where: "_load_date = current_date"   # test only today's data (cheap on big tables)
        store_failures: true    # save failing rows to a table to inspect
```

---

## Part 6. Naming: what dbt enforces vs what is convention

### Strict rules (break them and dbt errors or misbehaves)
| Rule | What happens if broken |
|---|---|
| **Model name = file name** (without `.sql`). There's no separate "name" field. | — (it's just how it works) |
| **Model / seed / snapshot names are unique across the whole project**, regardless of folder | Hard error: `dbt found two models with the name "int_drugs"` **(verified)**, because `ref()` looks up by name only |
| Names must be valid identifiers: letters, digits, underscores. No spaces or dots. | Space in a file name: runtime error **(verified)**. Hyphens and capitals cause quoting trouble in many warehouses; avoid them |
| Reserved file names: `dbt_project.yml`, `profiles.yml`, `packages.yml`, `dependencies.yml`, `selectors.yml` | dbt reads them by exact name |
| `name:` in `dbt_project.yml`: lowercase letters, digits, underscores | Parse error |
| YAML top-level keys are fixed: `version`, `models`, `sources`, `seeds`, `snapshots`, `macros`, `analyses`, `exposures`, `unit_tests`, `semantic_models`, `metrics`, `saved_queries` | Unknown keys are rejected or ignored |
| A YAML `- name:` must match an existing node exactly | Only a **warning**, and the entry's tests are silently skipped (your `__types` typo). Make it an error in CI: `--warn-error-options '{"error": ["NoNodeForYamlKey"]}'` |
| Macro names are unique within a package (except intentional overrides of built-ins) | Hard error on duplicates |
| Generic test definitions use `{% test name(model, ...) %}`; singular tests are one SELECT returning failing rows | Doesn't parse, or the test passes/fails incorrectly |
| `ref()` only to models / seeds / snapshots; `source()` only to declared sources | Compilation error |
| Folder names under `models:` in `dbt_project.yml` must match real folders (`silver:` = `models/silver/`) | Config silently doesn't apply |

### Conventions (not enforced, but everyone expects them)
From dbt Labs' project-structure guide; this is what reviewers look for:

| Prefix | Layer | Pattern | Our project |
|---|---|---|---|
| `stg_` | bronze / staging: 1:1 with a source table; rename, cast, nothing else | `stg_<source>__<entity>` | `stg_pharmacy_claims` (strict form: `stg_raw__pharmacy_claims`) |
| `int_` | silver / intermediate: joins, dedup, business logic | `int_<entity>__<verb or step>` | `int_pharmacy_claims__typed`, `int_pharmacy_claims__quarantine` |
| `fct_` | gold facts: events, one row per thing that happened | `fct_<event>` | `fct_pharmacy_claim` (Class 4) |
| `dim_` | gold dimensions: entities | `dim_<entity>` | `dim_member`, `dim_drug` |
| `mart` / `rpt_` / `agg_` | aggregates for a consumer | `rpt_pmpm_by_client` | Class 4 |

**The double underscore `__`** separates parts of a name that themselves contain single underscores: `stg_` + `raw` + `__` + `pharmacy_claims`. It lets you read the source and the entity apart.

**YAML property files:** one per folder, prefixed `_` so they sort to the top: `_sources.yml`, `_bronze_models.yml`, `_silver_models.yml`. The file name itself is free.

**Column naming:**
| Pattern | Meaning | Example |
|---|---|---|
| `<entity>_id` / `_key` | identifiers; `_key` for built or surrogate keys | `transaction_id`, `member_key`, `fill_key` |
| `is_` / `has_` / `was_` | booleans | `is_quarantined`, `was_reversed` |
| `_at` | timestamps (UTC) | `submitted_at`, `quarantined_at` |
| `_date` | dates | `date_of_service`, `coverage_start_date` |
| `_amount` / `_cost` | money, with units clear | `plan_paid_amount` |
| `_raw` | untouched original, kept next to a cleaned version | `ndc_raw`, `name_raw` |
| `_` prefix | pipeline metadata, not business data | `_load_date`, `_source_file` |
| `dq_` | data-quality flags (our convention) | `dq_orphan_member` |

Plus: lowercase snake_case everywhere, no reserved words as column names (`date`, `order`, `group`), and singular test names that read as the rule (`assert_...`).

---

## Part 7. Selectors: running part of the DAG
| Command | Runs |
|---|---|
| `dbt build -s int_pharmacy_fills` | just that model and its tests |
| `dbt build -s +int_pharmacy_fills` | it and **everything upstream** (needed on an empty database; Class 2 lesson) |
| `dbt build -s int_eligibility+` | it and everything downstream (after changing eligibility logic) |
| `dbt build -s silver` or `-s path:models/silver` | a folder |
| `dbt build -s tag:pii` | everything tagged `pii` |
| `dbt build -s source:raw+` | everything fed by the `raw` source |
| `dbt build -s state:modified+ --state prod-artifacts/` | only what changed, plus downstream: **Slim CI** (Class 5) |
| `dbt build --exclude stg_rebates` | everything except |
| `dbt test -s test_type:singular` | only singular tests |

---

## Part 8. Where to look when something is wrong
| File | What it tells you |
|---|---|
| `target/compiled/<project>/models/.../x.sql` | your SELECT after Jinja: refs and macros resolved |
| `target/run/<project>/models/.../x.sql` | the full DDL actually sent to the warehouse |
| `target/compiled/.../_silver_models.yml/<test>.sql` | the SQL behind a generic test (the build output prints this path on failure) |
| `target/manifest.json` | every node, config, dependency |
| `target/run_results.json` | status and timing of the last run |
| `logs/dbt.log` | full debug log, including parse **warnings** that scroll off the screen |

---

## 30-second interview answer
"dbt runs in two phases. Parse reads the whole project, macros first, then models, YAML, tests and seeds. Rendering the Jinja with `ref()` and `source()` builds a dependency graph, and it writes `manifest.json`. Execute then walks that DAG in dependency order with parallel threads. Each model is compiled, wrapped in its materialization's DDL and run, and in `dbt build` its tests run right after it, so an error-level failure skips everything downstream. File order never matters; only `ref()` does. Names are the contract: model names are unique project-wide because `ref` resolves by name, and a YAML entry that doesn't match a model is only a warning. So in CI I promote that warning to an error."
