-- Point-in-time vs "current plan" attribution of paid spend.
-- Wrong way: join every fill to the member's CURRENT plan. Right way: the plan in force on the date of service.
with paid as (
    select * from {{ ref('int_pharmacy_fills') }} where fill_status = 'paid'
),

attributed as (
    select
        f.fill_key,
        f.plan_paid_amount,
        cur.plan_id                                   as current_plan,
        pit.plan_id                                   as plan_at_service,
        pit.member_key is null and cur.member_key is not null as no_coverage_on_service_date
    from paid f
    left join {{ ref('int_eligibility') }} cur
      on cur.member_key = f.member_key
    left join {{ ref('int_member_coverage_spans') }} pit
      on pit.member_key = f.member_key
     and f.date_of_service between pit.effective_from and pit.effective_to
)

select
    case
        when current_plan is null                    then 'orphan (no eligibility)'
        when no_coverage_on_service_date             then 'no coverage on date of service'
        when current_plan = plan_at_service          then 'same plan'
        else 'plan changed: current plan is WRONG'
    end                                               as attribution,
    count(*)                                          as fills,
    sum(plan_paid_amount)                             as plan_paid
from attributed
group by 1
order by 2 desc