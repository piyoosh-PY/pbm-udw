-- Class 5: which client-months were RESTATED after we first published them, and by how much?
-- Run: dbt compile -s pmpm_restatements, or paste into `dbt show --inline`.
with versions as (
    select
        client_id, plan_id, service_month,
        plan_paid_pmpm, plan_paid, member_months, paid_fills,
        dbt_valid_from,
        row_number() over (partition by client_id, plan_id, service_month order by dbt_valid_from) as version_no,
        count(*)     over (partition by client_id, plan_id, service_month)                         as versions
    from {{ ref('snap_client_month_metrics') }}
)
select
    client_id, plan_id, service_month, version_no, dbt_valid_from as published_at,
    paid_fills, plan_paid, member_months, plan_paid_pmpm,
    plan_paid_pmpm - lag(plan_paid_pmpm) over (partition by client_id, plan_id, service_month order by version_no) as pmpm_change
from versions
where versions > 1
order by client_id, plan_id, service_month, version_no
