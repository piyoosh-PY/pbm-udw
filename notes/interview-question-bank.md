# Interview question bank (from real interviews + prep)

Newest first. For each: what was asked, what I said, what was missing, and the better answer.
Answer rules: **make the point, one example or number, stop** (my weak spot is over-answering).
For "how would you build X": **Question -> Grain -> Sources -> Layers -> Metrics -> Tests -> Consumers.**
For tools I haven't used: "I haven't used X directly; the closest I've done is Y; here's how I'd approach it."

---

## A. Rightway, 1st round with Aditya (Director), 2026-10-23

### A1. "Walk me through your experience."
- **Said:** background and experience. **Self-review:** nervous; didn't walk end to end.
- **Better:** past -> present -> bridge to the role, 2 numbers, 1 AI point, end on why this role (see B1).

### A2. "How would you build a data mart?"
- **Said:** bronze -> silver -> gold, mart based on business needs. ✅ correct start.
- **Missing:** the end-to-end walk. **Better:** "Start from the business question and the consumer. Declare the grain. Land sources as received in bronze; clean, dedup and conform in silver (one member, one drug, one provider definition); gold = star schema with SCD2 dims and point-in-time joins, then a mart at the reporting grain with additive measures so ratios re-divide correctly. Tests at every layer: unique grain, relationships, tie-outs in dollars, semantic checks. Then schedule, monitor freshness, and snapshot what's published."

### A3. Case: "A weight-management program for 1,000 members, 800 not in the plan. What would the mart report?"
- **Said:** average weight on the gold fact (weight changes over time); mark members not in the plan as **orphans**; success rate for both groups; check with business whether non-enrolled / not-in-plan members should be included. ✅ the business-logic check was a strong move.
- **What was off:**
  - "Orphan" = a claim with no eligibility record (a data problem). Non-enrolled members are a valid **comparison cohort**.
  - **Average weight** hides what matters and ignores different starting points.
  - Missed the **GLP-1 / PBM money link** (Rightway SureSpend carves out GLP-1 cost).
- **Better answer:**
  - Question: does the program work, and what does it save?
  - Grain: `fct_weight_measurement` = one row per member per weigh-in (weight is a measure); `fct_program_enrollment` = one row per enrollment episode; `fct_member_program_outcome` = one row per enrollment (baseline, latest, % change).
  - Metrics: enrollment rate (200 / 1,000), engagement (weigh-ins per month), **% achieving >= 5% loss from own baseline**, time to 5%, **GLP-1 fills, adherence (PDC) and Rx spend PMPM**, participants vs a similar non-participant group.
  - Caveats: **selection bias** (enrollees are more motivated): compare matched cohorts or pre/post; confirm with business who counts (not in plan vs not enrolled).
  - Consumers: client report, care team outreach list.

### A4. "How does your surrogate key work?" (came up with the weight case)
- **Said:** weight + version in the surrogate key, read from the snapshot, md5 while updating the fact.
- **What was off:** a measure never belongs in a key. Keys = stable identity + version start. Weight changes on every reading and on corrections -> unstable keys, orphaned facts, collisions.
- **Better answer:** "Weight is an event, so it lives in a fact: one row per member per weigh-in, keyed `md5(member_key | measured_at | source)`, weight as the measure, `member_sk` via point-in-time join to the SCD2 member version. Corrections keep the same key and update the value; if I need correction history I snapshot the source feed. I wouldn't make weight an SCD2 attribute on the member dimension: it's a rapidly changing attribute, so it moves to a fact, or a small mini-dimension of BMI bands if people slice by it."

### A5. "Rate yourself: SQL, dbt, Python."
- **Said:** 7 / 7.5 / 8. **Self-review:** under-rated myself.
- **Better:** number + one line of evidence. "SQL 8: window functions, dedup and reconciliation logic daily in Snowflake. dbt 7.5: personal projects with incremental models, snapshots and unit tests, the same patterns at work in Snowflake. Python 8: production APIs and pipelines since 2017."

### A6. "dbt run vs dbt build?"
- **Said:** build = complete flow (parse, compile, run); run = runs the given model only. Mostly right.
- **Better:** "Both parse and compile and both take selectors. `run` builds only models. `build` runs seeds, models, snapshots and tests together in DAG order, and a failed test skips everything downstream, so bad data never reaches the marts. `build` in production and CI, `run` while iterating on one model." (Real example: Oct 3 `unique_dim_member` failure skipped 21 downstream nodes.)

### A7. AI discussion: "How did you add MCP tools, the connector layer, and how does it pick an LLM?"
- **Went well:** follow-up questions = genuine interest. Covered MCP tools (Atlassian, Snowflake Cortex, SQL Server, job orchestrator), the connector layer, routing by task complexity.
- **Keep ready:** eval-gated skill updates (changes ship only when they beat golden datasets); -40% manual investigation; model-agnostic by design.

### A8. PBM + care navigation and preventive care
- **Went well:** linked to VBC quality metrics (care gaps, attribution).
- **Add next time:** the money link: transparent PBM (per-member fee, 100% rebate pass-through, no spread) only works if every number is auditable; navigation steers members to high-value care and drugs.

---

## B. Prepared answers (mock, 2026-10-22)

### B1. Tell me about yourself
"Analytics engineer, ~6 years. Started as a Python backend developer (led 2 engineers at a startup), moved into data with a master's, and for 3+ years at Elevance built the models behind value-based care analytics for ~13M members across 14 markets: claims, eligibility, provider. Turned attribution and payment rules into tested, auditable logic: +38% accuracy, -60% reconciliation work. Built an LLM assistant with MCP tools my team uses daily. Lately going deep on PBM data, building a pharmacy claims warehouse in dbt, which is why this role caught my eye."

### B2. Why Rightway?
"The model: a transparent PBM only works if every number can be audited, which is the work I like. The timing: Series E, 45 Fortune 500 clients, the analytics platform has to scale. And the JD names Claude, Claude skills and MCP, which I build today."

### B3. A time your data was wrong
The empty-span story (class-05 Step 6–8): unique test failed -> new add + retro change -> empty coverage span -> fixed in silver, not by changing the key. "Ask whether the data is wrong or the rule is; fix the cause, not the test."

### B4. How do you make sure a number you send a client is right?
"Define it before SQL (grain, numerator, denominator, edge cases). Tie out every layer in counts and dollars. Tests with consequences, including semantic tests that compute the answer independently. Keep a history of what was published, so a restatement becomes an explanation."

### B5. "September doesn't match the report you sent."
"Data changed after we published, and I can show exactly what. We snapshot every published version: CL001's September went out with 2,755 paid fills; after the Oct 4 load it's 2,731, because pharmacies reversed 24 September claims. Member months didn't change, so PMPM dropped. To avoid surprises: flag months still settling and agree a close date, after which changes are reported as restatements."

### B6. Orchestration / "Have you used Airflow or Dagster?"
"In production I've used Step Functions and Lambda: EventBridge triggers on schedule or file arrival, a Lambda validates inputs against control totals, a Choice state stops on mismatch, Glue jobs do the heavy work, Retry blocks handle transient errors with backoff, Catch routes to alerts. The same design in Airflow is a DAG with an S3 sensor, task retries and failure callbacks; in Dagster, dbt models become assets with daily partitions, so backfills replay load dates in order, which matters because snapshots capture history only in run order. Principles don't change: gate on completeness, retry transient errors never data-test failures, idempotent steps, one load at a time."
- Before using: match the details to what I actually built at Elevance (don't claim `.sync` Glue or manifest checks unless true).
- Follow-ups: dbt from Step Functions -> ECS/Fargate task (not Lambda: 15-min limit); backfill -> Map state over dates with concurrency 1.

### B7. Deletes in incremental models
"delete+insert and merge only touch keys in the batch, so deletes need their own path: soft-delete flag, post-hook delete, or MERGE with a delete branch. MERGE when atomicity matters (customer-facing tables read during loads), via a custom incremental strategy in dbt; a post-hook delete keyed on source status is simpler, portable and idempotent, with a small non-atomic window."

### B8. Unit tests vs data tests
"Data tests check the data I have; unit tests check the logic against cases I don't have yet. When I disabled one incremental trigger, a retro-termed claim stayed 'covered' and every data test still passed; only the unit test caught it."

---

## C. More by topic
Class-specific question lists with answers: Class 1–3 "Interview answers" sections, Class 4 Part 4 (questions by step) and Part 5, Class 5 "30-second answers". See [README index](README.md).
