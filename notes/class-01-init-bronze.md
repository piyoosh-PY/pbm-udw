# Class 1: Init + Bronze (2026-10-16)

## What I built
- Repo `pbm-udw` (git + GitHub), Python 3.12 venv, dbt Core 1.12 + dbt-duckdb 1.11, project-local `profiles.yml`.
- Dirty-data generator: one daily load = ~21.5K NCPDP-style claims, ~2.7K eligibility rows, drug, provider and rebate files, Hive-partitioned (`load_date=YYYY-MM-DD`), plus a defect manifest (19 defect types, ~2,600 defects).
- Bronze layer: 5 sources read as text through `external_location`, 5 `stg_` views with lineage columns (`_load_date`, `_source_file`, `_file_loaded_at`).
- Tests: not_null, unique (severity warn), accepted_values, source freshness, and a control-total reconciliation against the manifest.
- Result: `dbt build` PASS=10 WARN=1 (unique test: 150 transaction ids delivered twice; the test counts duplicated values, not rows); freshness ERROR STALE (expected: file dated Sep 30).

Deep reference on YAML keys, config, and what dbt runs behind the scenes: [dbt-reference.md](dbt-reference.md)

## Concepts
- **ETL vs ELT:** where the T runs. Cloud warehouses split storage from compute, so ELT became the default; real systems are hybrid (light T in flight, business logic in the warehouse).
- **Parse in flight, net in the warehouse:** reversals arrive days later in other files; only the warehouse has the history.
- **PHI:** tokenize at ingestion, detokenize at the edge, role-based masking in between.
- **Medallion:** bronze = evidence (as received, never overwritten), silver = truth (cleaned, conformed once), gold = answer (per consumer). No dashboard reads bronze.
- **dbt:** you write SELECTs; dbt compiles, wraps in DDL, orders by the DAG from `ref()`/`source()`, tests, documents. `source()` = raw tables dbt doesn't build; `ref()` = dbt models (environment-aware names, build order, lineage).
- **Lossless bronze:** read everything as text. Inferred types drift with each day's dirt (50 "$" rows turned an amount column into text).
- **Test severity:** error blocks the pipeline, warn flags and continues. Duplicates are expected in bronze, so warn; silver must remove them.
- **Control totals:** reconcile row counts to the sender's manifest before any business logic.
- **Schema naming:** dbt's default `generate_schema_name` gives `main_bronze` so developers don't collide.
- **Paths:** "No such file or directory" in a connection test = working-directory/path problem, not credentials.

## 30-second interview answers
- **ETL vs ELT:** "ETL transforms before loading, ELT loads raw and transforms in the warehouse. Cloud warehouses made ELT the default, and dbt makes the T version-controlled and tested. I run a hybrid: parse and tokenize in flight, business logic in dbt, so raw stays replayable."
- **Medallion + dbt:** "Bronze lands data as received and is never overwritten, so we can replay. Silver applies business rules once: dedup, reversal netting, conformed member and drug. Gold models for each consumer. ref and source give lineage, tests run at every layer, so a client number traces back to raw rows."
- **Bronze design:** "For dirty partner files I keep bronze lossless, all text plus lineage columns, and cast in silver, so a bad value becomes a visible test failure instead of a silent NULL. I reconcile row counts to the sender's control totals and alert on freshness, because a missing feed is the most common failure."
