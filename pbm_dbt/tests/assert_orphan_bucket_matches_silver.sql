-- Semantic check: the -1 (orphan) bucket must equal paid fills whose member has NO eligibility record at all,
-- computed independently from silver. Catches a wrong bucket definition that every total/structure test would miss.
with expected as (
    select count(*) as n
    from {{ ref('int_pharmacy_fills') }} f
    where f.fill_status = 'paid'
      and not exists (select 1 from {{ ref('int_eligibility') }} e where e.member_key = f.member_key)
),
actual as (
    select count(*) as n from {{ ref('fct_pharmacy_claim') }} where member_sk = '-1'
)
select e.n as expected_orphans, a.n as actual_orphans
from expected e cross join actual a
where e.n <> a.n