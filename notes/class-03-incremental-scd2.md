# Class 3: Incremental models + history (SCD2) (2026-10-17)

Final state: 3 file drops (Sep 30, Oct 1, Oct 2), `dbt build` -> PASS=45 WARN=2 TOTAL=47 (incl. 6 toy playground nodes)

## Part 1. Explain it simply (the toy lab)
Source: an `orders` table re-sent in full each day (`seeds/toy_orders.csv`). Four loaders, compared with `analyses/toy_compare.sql`.

| Day | What changed in the source | Full refresh | Append + watermark | Merge + watermark | Merge + lookback |
|---|---|---|---|---|---|
| 1 | 3 orders | ok | ok | ok | ok |
| 2 | Bob cancels; Dan new; Ann corrected to $120 with an OLD timestamp (late) | ok | Bob twice (duplicate) | Ann stuck at $100 (late row missed) | ok |
| 3 | Cat deleted (row gone) | ok | Cat remains | Cat remains | Cat remains |
| 4 | Cat re-sent as `status = deleted` (tombstone) | ok | Cat twice | ok | ok |

**Three failure modes and their fixes**
| Failure | Why | Fix |
|---|---|---|
| Duplicates | append only inserts | `merge` / `delete+insert` with `unique_key` (also makes reruns idempotent) |
| Late rows missed | `updated_at > max(updated_at)` skips anything stamped older than the watermark, forever | lookback window: re-read last N days; merge makes re-reading harmless |
| Deletes missed | an incremental run only acts on rows IN THE BATCH; a missing row never enters the batch. Absence can't be seen | make deletes rows: tombstones (status column) or CDC `op = D`; filter downstream. Last resort: periodic full refresh |

**CDC vs full-file feed:** full file = whole table every day, deletes must be inferred (our 834). CDC = only changes, each with I/U/D, deletes explicit, much smaller (my Elevance CDC loads cut runtime 30%).

**Snapshots (SCD2):** full refresh and merge overwrite (SCD1). A snapshot keeps every version with `dbt_valid_from/to`.
- `timestamp` strategy: change = `updated_at` moved; valid_from = source time.
- `check` strategy: change = any `check_cols` differ; valid_from = when the snapshot RAN. Use when there's no trustworthy updated_at (834 full file).
- `hard_deletes: invalidate` closes rows that vanish from the source.
- Not reproducible: history exists only for runs that happened. Bronze keeps raw files so history can be rebuilt.

## Part 1b. The same day-by-day table, for PBM (real rows from our data)

### What arrives in each file
| Example | Sep 30 file (Day 1) | Oct 1 file (Day 2) | Toy equivalent |
|---|---|---|---|
| **Fill A** `1132677364\|1213993\|3\|2026-09-24` | B1 paid, plan paid $197.55 | **B2 reversal** for that same fill (late event: the fill was in yesterday's file) | Cat deleted, sent as a tombstone (Day 4), but arriving one file later |
| **Fill B** `1176936767\|8505519\|3\|2026-09-29` | B1, then B2, then B3 rebill, **all in the same file** | nothing | Bob placed then cancelled on the same day |
| **Claim C** `T202609300012395` (member `RW980181-01`, $197.55) | Claim arrives; member NOT in eligibility, so it's an orphan | Member's eligibility finally arrives (retro start Sep 1) | Ann's late correction: the answer changes because of a later row |
| **Member D** `RW101530-01` | Plan PPO_RX_A | **001 plan change** to PPO_RX_B, effective **Sep 15** (retro) | Bob's status changes; the snapshot keeps both versions |
| **Member E** `RW101978-01` | Active, no end date | **024 termination**, effective **Sep 20** (retro) | — |
| **Duplicate row** | 150 transactions sent twice | 150 more | Bob twice under append |

### What silver shows after the Oct 1 run, by approach
| Example | Full refresh (truth) | Append-only incremental | Merge, naive (Class 3 Step 4) | Fixed (Class 3 Step 6) |
|---|---|---|---|---|
| Fill A | reversed: not counted | ❌ still paid $197.55 (B2 batch is filtered out, nothing inserted) | ❌ still paid $197.55 (key not in batch, so merge can't touch it) | ✅ `fill_status = reversed` (tombstone overwrites the paid row) |
| Fill B | paid as B3 | ✅ B3 (whole lifecycle in one batch) | ✅ | ✅ |
| Claim C | not an orphan | ❌ still flagged orphan (row never reprocessed) | ❌ still flagged without the re-check | ✅ flag cleared (typed re-reads rows still flagged orphan) |
| Duplicate row | counted once | ❌ counted twice on a rerun | ✅ (merge on transaction_id) | ✅ |
| Member D, current state (`int_eligibility`, SCD1) | PPO_RX_B | — | — | PPO_RX_B, but history overwritten |
| Member D, history (snapshot, SCD2) | **can't**: full refresh only knows "now" | — | — | v1 PPO_RX_A Jan 1–Sep 14, v2 PPO_RX_B Sep 15→ |
| Member D's Sep 13 fill ($483.90): which plan? | current-plan join says PPO_RX_B ❌ | — | — | point-in-time join says **PPO_RX_A** ✅ |
| Member E's Sep 25 fill ($197.55) | looks normal | — | — | PIT join finds **no coverage on the date of service** (paid after the retro-term; a recovery candidate) |

**The lesson in one line:** anything that happens inside one file is easy (Fill B). Anything that **changes a row from an earlier file** (Fill A, Claim C, Member D, Member E) breaks naive incremental logic. You need: tombstones (A), re-checking flagged rows (C), and history plus effective dating (D, E).

### Totals at each stage
| Moment | Paid fills | Reversed | What it proves |
|---|---|---|---|
| Sep 30 (Class 2) | 19,059 | (filtered out) | baseline |
| Oct 1, naive fills | 80 too many "paid" | — | `FAIL 80`: merge can't delete |
| Oct 1, fixed | 21,552 | 778 | tombstones work (via full refresh) |
| Oct 2, fixed, incremental | 24,060 | 935 | the incremental path works; full refresh gives identical numbers |

## Part 2. Theory recap
- `is_incremental()` true only if the table exists, is a table, and no `--full-refresh`. `{{ this }}` = the existing table.
- Strategies: append (events, not idempotent) / merge (upsert by key) / delete+insert (replace whole key groups) / insert_overwrite (partitions) / microbatch (time batches, 1.9+).
- Changing columns or materialization of an incremental model -> schema-sync error with `on_schema_change='fail'` -> run `--full-refresh` once (or `append_new_columns` / `sync_all_columns`).
- Two kinds of late: **late file** (fix: lookback) vs **late event** that changes a multi-file grain (fix: recompute affected keys from full history + tombstones).
- Idempotency proof: incremental result == full-refresh result (a test).
- Bitemporal: system time (snapshot `dbt_valid_from`, when we learned it) vs business time (834 effective date, when it was true). Claims join on business time.

## Part 3. What I built (PBM)
- Generator: later loads evolve the 834 roster (030 audit, retro 001 plan changes eff. load-16d, retro 024 terms eff. load-11d, new 021 adds, late eligibility for prior orphans) and emit 80 late B2s per load for clean, still-paid prior fills. Sep 30 claims byte-identical (seeded).
- Schema evolution: `maintenance_effective_date` added; `union_by_name=true` in the source.
- `int_eligibility`: `is_never_effective` (end = start - 1) split from `dq_coverage_end_before_start` (Class 2 lesson): 3 vs 8.
- `snap_member_eligibility` (check strategy).
- `int_pharmacy_claims__typed`: incremental merge on transaction_id; lookback `claims_lookback_days`; re-checks rows still flagged orphan / unknown NDC; `_processed_at` watermark.
- `int_pharmacy_fills`: incremental delete+insert on fill_key; touched fills recomputed from full history via macro `net_pharmacy_fills`; tombstones (`fill_status` paid / reversed / rejected).
- `int_member_coverage_spans`: effective-dated spans from the snapshot (business + system time).
- Tests: `assert_no_paid_fill_has_a_later_reversal`, `assert_fills_incremental_matches_full_recompute`, `assert_coverage_spans_do_not_overlap`; defect test updated for late reversals and resolved orphans.

## Results
| Moment | Result |
|---|---|
| Oct 1 with NAIVE fills | FAIL 80: 80 Sep fills still "paid" after their late B2 |
| Orphan re-check (Oct 1) | orphans 80 -> 70: 10 resolved when eligibility arrived |
| After fix (Oct 1) | paid 21,552 / reversed 778 / rejected 600 |
| Oct 2 (incremental path) | paid 24,060 ($6,986,722.16) / reversed 935 / rejected 900; full refresh identical |
| Snapshot | 2,853 versions, 2,773 members, 80 closed (25 plan + 15 term per load) |
| Point in time vs current plan | 182 fills / $45.6K on the wrong plan with a current-plan join; 628 fills / $232K paid with no coverage on the date of service (51 after retro-terms) |

Trap: reversed tombstones carry the B2's positive amounts ($194K-$248K). Every consumer must filter `fill_status = 'paid'`; gold will enforce it.

## Why delete+insert alone doesn't fix late reversals
The late B2 is already IN the new file, so lookback isn't the issue. The issue is the netted OUTPUT: if reversed fills are filtered out (`where code in ('B1','B3')`), the fill_key never appears in the batch, and delete+insert only deletes keys present in the batch. The old paid row survives. Two pieces are needed: (1) recompute each touched fill from its full history (old B1 + new B2), and (2) emit a tombstone row so the key is in the batch and overwrites the paid row.

## Interview answers (30 seconds)
- **Incremental vs full refresh?** Full refresh until cost forces otherwise; incremental is an optimization you must prove: merge on a business key, lookback for late files, tombstones for deletes, and a test that incremental equals full refresh.
- **Late-arriving data?** Separate late files (lookback + merge) from late events that change an aggregate grain (recompute affected keys from full history; keep tombstones).
- **Deletes in incremental models?** Invisible by absence; make them rows (status / CDC op D) or reconcile with periodic full refresh.
- **SCD2?** Snapshot with timestamp or check strategy; join on valid_from/valid_to. Distinguish system time from business effective time for claims (retro eligibility).
- **What did the PIT join find?** $45.6K attributed to the wrong plan with a naive current-plan join, and $232K paid on dates with no coverage: an eligibility/adjudication sync issue or a recovery opportunity.
