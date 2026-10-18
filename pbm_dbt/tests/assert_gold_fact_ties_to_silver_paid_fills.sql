-- Gold must not gain or lose a single paid fill or dollar on the way from silver.
with silver as (
    select count(*) as fills, sum(plan_paid_amount) as plan_paid
    from {{ ref('int_pharmacy_fills') }} where fill_status = 'paid'
),
gold as (
    select count(*) as fills, sum(plan_paid_amount) as plan_paid
    from {{ ref('fct_pharmacy_claim') }}
)
select s.fills as silver_fills, g.fills as gold_fills, s.plan_paid as silver_paid, g.plan_paid as gold_paid
from silver s cross join gold g
where s.fills <> g.fills or s.plan_paid <> g.plan_paid