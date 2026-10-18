-- The client mart must account for every fact dollar (UNATTRIBUTED included) and every member month it reports on.
with mart as (
    select sum(plan_paid) as plan_paid, sum(paid_fills) as fills, sum(member_months) as member_months
    from {{ ref('mart_client_month_metrics') }}
),
fact as (
    select sum(plan_paid_amount) as plan_paid, count(*) as fills from {{ ref('fct_pharmacy_claim') }}
),
mm as (
    select sum(member_month) as member_months
    from {{ ref('fct_member_month') }}
    where month_start >= (select date_trunc('month', min(date_of_service)) from {{ ref('fct_pharmacy_claim') }})
      and month_start <= (select max(date_of_service) from {{ ref('fct_pharmacy_claim') }})
)
select mart.plan_paid as mart_paid, f.plan_paid as fact_paid, mart.fills as mart_fills, f.fills as fact_fills,
       mart.member_months as mart_mm, mm.member_months as spine_mm
from mart cross join fact f cross join mm
where mart.plan_paid <> f.plan_paid or mart.fills <> f.fills or mart.member_months <> mm.member_months