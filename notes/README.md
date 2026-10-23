# PBM UDW learning series: index

Mini pharmacy-benefits + eligibility warehouse on deliberately dirty data, built class by class (dbt Core 1.12 + DuckDB; AWS in Class 6).
Start here, then follow a class or jump to a topic.

## Classes
| # | Notes | Date | Built | Status |
|---|---|---|---|---|
| 1 | [Init + Bronze](class-01-init-bronze.md) | Oct 16 | generator + defect manifest, 5 sources as text, staging views, control totals, freshness | done |
| 2 | [Silver: cleaning dirty data](class-02-silver.md) | Oct 17 | cleaning macros, dedup, quarantine, reversal netting, defect-coverage tests | done |
| 3 | [Incremental + history (SCD2)](class-03-incremental-scd2.md) | Oct 17 | toy incremental lab, incremental claims + fills, tombstones, eligibility snapshot, coverage spans | done |
| 4 | [Gold: dimensional model + metrics](class-04-gold.md) | Oct 18 | dims (SCD2 member), point-in-time fact, member months, PMPM / GDR mart, rebate reconciliation, tie-out + semantic tests | done |
| 5 | [Incremental gold, gold snapshot, unit tests](class-05-incremental-gold-snapshot-tests.md) | Oct 21–22 | incremental fact (3 triggers + delete path), spans bug fix, mart snapshot (restatements), unit tests | Part 1 mostly done; generic tests, contract, CI, pytest, Dagster pending (reference on branch `class5-reference`) |
| 6 | AWS integration + production | — | S3 landing, Lambda trigger, Glue catalog, dbt on Athena | not started (theory crash notes on `class5-reference`) |

## Reference docs
| Doc | Covers |
|---|---|
| [dbt-reference.md](dbt-reference.md) | every file type, `dbt_project.yml`, `profiles.yml`, source / model YAML keys, what `dbt build` does behind the scenes |
| [dbt-execution-order-and-naming.md](dbt-execution-order-and-naming.md) | parse vs execute phases, how `ref`/`source`/`var` resolve, test naming, selectors, where to look when something's wrong |
| [dbt-materializations-and-dag.md](dbt-materializations-and-dag.md) | view / table / incremental / ephemeral with the SQL dbt ran, our DAG, nodes and tests, command cheat sheet |
| [interview-question-bank.md](interview-question-bank.md) | real interview questions (Rightway 1st round) with better answers, plus prepared answers |

## Topic index
| Topic | Where |
|---|---|
| ETL vs ELT, medallion, lossless bronze, control totals | Class 1 |
| Data-quality dimensions, 4 kinds of duplicates, deterministic ordering | Class 2 Theory |
| Repair vs quarantine vs flag, reconciliation identity | Class 2 Theory |
| Reversals (B1 / B2 / B3), fill grain, rebate vs rebill | Class 2; Class 4 Part 0 |
| Silently skipped tests (typo in model name, node count) | Class 2 Lessons #1; Class 4 Validation pass |
| Incremental strategies (append / merge / delete+insert / insert_overwrite / microbatch) | Class 3 Part 2; dbt-materializations-and-dag §2 |
| Late files vs late events, lookback, watermark, tombstones | Class 3 Part 1 + "Why delete+insert alone doesn't fix late reversals" |
| `is_incremental()`, `{{ this }}`, `--full-refresh`, `on_schema_change` | Class 3 Part 2; Class 5 Step 2 |
| Snapshots: timestamp vs check, `hard_deletes`, system vs business time (bitemporal) | Class 3; Class 4 Q1; Class 5 Step 13 |
| SCD1 vs SCD2 per column, surrogate keys (md5, stable inputs only) | Class 4 Steps 1–2; Class 5 Step 6–8; Question bank A4 |
| Grain, fan-out, special rows (-1 / -2), role-playing / conformed dims | Class 4 Part 1, Step 3 |
| Point-in-time join, paid-without-coverage (recovery) | Class 3 Results; Class 4 Step 3 |
| Member months, counting day, PMPM traps, GDR | Class 4 Steps 4a–4b |
| Rebate reconciliation, confidence (lower bound) | Class 4 Step 5 |
| Tie-out vs semantic tests ("tests check structure, not meaning") | Class 4 Step 6, Experiment 2 |
| Incremental gold: change triggers, `depends_on` hint, cascading lookbacks | Class 5 Steps 1–5 |
| Deletes in incremental models: soft delete vs post_hook vs MERGE | Class 5 Steps 9–10; Question bank B7 |
| Restatements: snapshot of published metrics, client explanation | Class 5 Steps 13–14; Question bank B5 |
| Unit tests vs data tests, `overrides`, `input: this`, daff diff | Class 5 Step 15; Question bank B8 |
| `dbt run` vs `dbt build` | dbt-materializations-and-dag §6; Question bank A6 |
| Partial-parse cache, dbt Fusion vs Core, pinning versions | Class 5 Steps 0, 13; Class 4 Validation #4 |
| Orchestration: scheduling, gates, retries, backfills, Step Functions -> Airflow / Dagster | Question bank B6 |
| Querying DuckDB directly (UI, CLI, Harlequin), single-writer lock | Class 5 Step 13–14 |
| PHI / HIPAA minimum necessary | Class 1 Concepts; Class 4 Part 1 |
| Weight-management / program-evaluation case | Question bank A3 |

## Data loads in the warehouse
| Load | Contents | First used |
|---|---|---|
| 2026-09-30 | base: ~20K claims, full 834, drugs, NPIs, rebates | Class 1 |
| 2026-10-01, 10-02 | 3K claims each, 80 late reversals, retro plan changes / terms, late eligibility | Class 3 |
| 2026-10-03 | same pattern; surfaced the empty-span bug | Class 5 |
| 2026-10-04 | same pattern; 20 client-months restated | Class 5 |
Regenerate with `python generator/generate_pbm_data.py --load-date <date> [--late-reversals --claims 3000 --window-days 3]`.
