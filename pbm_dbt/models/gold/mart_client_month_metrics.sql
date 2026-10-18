-- Gold mart: the client report. GRAIN: one row per client x plan x service month.
-- Every ratio is computed from additive sums here, so rollups (client, total) must re-divide sums, never average ratios.
-- Claims with no covered member (member_sk -1 / -2) land in client 'UNATTRIBUTED' so the mart still ties to the fact.
with claims as (
    select
        coalesce(m.client_id, 'UNATTRIBUTED')                                  as client_id,
        coalesce(m.plan_id, 'UNATTRIBUTED')                                    as plan_id,
        f.service_month,
        count(*)                                                               as paid_fills,
        sum(f.adjusted_rx_count)                                               as adjusted_scripts,
        count(*) filter (where d.is_generic)                                   as generic_fills,
        count(*) filter (where d.is_generic is not null)                       as fills_with_known_drug,
        count(distinct f.member_key)                                           as utilizing_members,
        sum(f.gross_cost)                                                      as gross_cost,
        sum(f.patient_pay_amount)                                              as patient_paid,
        sum(f.plan_paid_amount)                                                as plan_paid,
        coalesce(sum(f.plan_paid_amount) filter (where d.is_specialty), 0)     as specialty_plan_paid,
        coalesce(sum(f.plan_paid_amount) filter (where not d.is_generic), 0)   as brand_plan_paid
    from {{ ref('fct_pharmacy_claim') }} f
    join {{ ref('dim_member') }} m on m.member_sk = f.member_sk
    join {{ ref('dim_drug') }}   d on d.drug_sk   = f.drug_sk
    group by all
),

member_months as (
    select client_id, plan_id, month_start as service_month, sum(member_month) as member_months
    from {{ ref('fct_member_month') }}
    group by all
),

data_window as (
    select min(date_of_service) as first_dos, max(date_of_service) as last_dos
    from {{ ref('fct_pharmacy_claim') }}
),

joined as (
    select
        coalesce(c.client_id, mm.client_id)                 as client_id,
        coalesce(c.plan_id, mm.plan_id)                     as plan_id,
        coalesce(c.service_month, mm.service_month)         as service_month,
        coalesce(mm.member_months, 0)                       as member_months,
        coalesce(c.paid_fills, 0)                           as paid_fills,
        coalesce(c.adjusted_scripts, 0)                     as adjusted_scripts,
        coalesce(c.generic_fills, 0)                        as generic_fills,
        coalesce(c.fills_with_known_drug, 0)                as fills_with_known_drug,
        coalesce(c.utilizing_members, 0)                    as utilizing_members,
        coalesce(c.gross_cost, 0)                           as gross_cost,
        coalesce(c.patient_paid, 0)                         as patient_paid,
        coalesce(c.plan_paid, 0)                            as plan_paid,
        coalesce(c.specialty_plan_paid, 0)                  as specialty_plan_paid,
        coalesce(c.brand_plan_paid, 0)                      as brand_plan_paid
    from claims c
    full outer join member_months mm
      on mm.client_id = c.client_id and mm.plan_id = c.plan_id and mm.service_month = c.service_month
)

select
    j.*,
    -- the metrics
    round(j.plan_paid / nullif(j.member_months, 0), 2)                        as plan_paid_pmpm,
    round(j.gross_cost / nullif(j.member_months, 0), 2)                       as gross_cost_pmpm,
    round(j.generic_fills / nullif(j.fills_with_known_drug, 0), 4)            as generic_dispensing_rate,
    round(j.specialty_plan_paid / nullif(j.plan_paid, 0), 4)                  as specialty_share_of_plan_paid,
    round(j.plan_paid / nullif(j.adjusted_scripts, 0), 2)                     as plan_paid_per_adjusted_script,
    round(j.patient_paid / nullif(j.gross_cost, 0), 4)                        as member_cost_share,
    round(j.adjusted_scripts / nullif(j.member_months, 0), 3)                 as adjusted_scripts_pmpm,
    -- trust flag: a month is reportable only if the claims data covers it end to end
    (j.service_month >= w.first_dos
        and j.service_month + interval 1 month - interval 1 day <= w.last_dos) as is_complete_month
from joined j
cross join data_window w
where j.service_month between date_trunc('month', w.first_dos) and w.last_dos   -- months with claims data only