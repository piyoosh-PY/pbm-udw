-- Which client-months were RESTATED after we first published them, and by how much?
with versions as (
    select
    client_id, plan_id, service_month,
    paid_fills, member_months, plan_paid, plan_paid_pmpm,
    dbt_valid_from,
    row_number() over (partition by client_id, plan_id, service_month order by dbt_valid_from) as version_no,
    count(*)     over (partition by client_id, plan_id, service_month)                         as versions
     from {{ ref('snap_client_month_metrics') }}

)
select
    client_id, plan_id, service_month, version_no, dbt_valid_from as published_at,
    paid_fills, member_months, plan_paid, plan_paid_pmpm,
    plan_paid_pmpm - lag(plan_paid_pmpm) over (partition by client_id, plan_id, service_month order by version_no) as pmpm_change
from versions
where versions > 1
order by client_id, plan_id,service_month,version_no