# PBM UDW: a mini Unified Data Warehouse for pharmacy benefits + eligibility

A hands-on build of a PBM-style data warehouse on deliberately dirty, synthetic data: NCPDP-style pharmacy claims (with reversals and rebills), 834-style eligibility, an NPPES-style provider sample and rebate files. Built class by class with dbt, DuckDB, Python and AWS (S3, Glue, Athena, Lambda, Step Functions).

All data is synthetic. No real PHI.

## Architecture (target)

```
raw files (S3 / local landing)
   -> bronze  : stg_ models, data as received, typed and renamed
   -> silver  : cleaned, deduplicated, reversals netted, conformed member / drug / provider
   -> gold    : star schema (fct_pharmacy_claim, dim_member, dim_drug, dim_provider), member-month spine, metrics
   -> consumers: client reporting, reconciliation, BI, AI agents
```

## Classes

| # | Class | Theory | Hands-on | Status |
|---|---|---|---|---|
| 1 | Init + Bronze | ETL vs ELT, medallion, dbt project anatomy, sources, freshness | git init, dbt init, DuckDB, dirty-data generator + defect manifest, sources, staging, first tests | done (2026-10-16) |
| 2 | Silver: cleaning dirty data | Data quality types, dedup strategies, quarantine vs drop, contracts | Reversal netting (B1/B2/B3), NDC 10 to 11, row_number dedup, NPI check digit, generic + singular tests, severity | done (2026-10-17) |
| 3 | Incremental + history | Full vs incremental, merge / append / delete+insert, late data, CDC, SCD1 vs SCD2 | Incremental claims with lookback, simulated change feed, eligibility snapshots, point-in-time joins | done (2026-10-17) |
| 4 | Gold: dimensional model + metrics | Grain, star schema, conformed dims, surrogate keys, semantic layer | dim_member, dim_drug, fct_pharmacy_claim, member-month spine, PMPM, generic rate, rebate reconciliation | done (2026-10-18) |
| 5 | Test suite + CI + orchestration | Test pyramid for data, unit vs data tests, contracts, slim CI, orchestrator design | Incremental gold fact (3 change triggers + delete path), gold mart snapshot (restatements), dbt unit tests, custom generic + threshold tests, contract, GitHub Actions CI | crash version done (2026-10-19); Dagster + pytest deep dive later |
| 6 | AWS integration + production | S3 lake, Glue, Athena, Lambda, Step Functions, IAM, cost, monitoring | S3 landing, Lambda on file arrival, Glue catalog, dbt on Athena, backfill runbook, mock interview | theory crash notes in class-05 (2026-10-19); hands-on later |

Class notes (theory, commands, results, 30-second interview answers) go in `notes/class-NN-<slug>.md`.

#MD5 (data/raw/pharmacy_claims/load_date=2026-09-30/claims.csv) = d0a7740ccf5e40fddce97f3f23156e6b
