-- Gold: member-month spine (the PMPM denominator).
-- GRAIN: one row per member per calendar month in which the member was covered on the counting day (default the 15th).
-- The member version (plan, client) is the one in force on the counting day.
-- covered_days / fractional_member_month are kept so the counting rule can be compared or swapped.
{% set counting_day = var('member_month_counting_day', 15) %}

with versions as (
    select * from {{ ref('dim_member') }}
    where member_key is not null
),

bounds as (
    select
        (select min(effective_from) from versions)                                    as first_day,
        (select max(cast(_load_date as date)) from {{ ref('int_pharmacy_fills') }})   as last_day   -- latest data we hold
),

months as (
    select cast(month_start as date) as month_start,
           cast(month_start + interval 1 month - interval 1 day as date) as month_end
    from (
        select unnest(generate_series(date_trunc('month', first_day), date_trunc('month', last_day), interval 1 month)) as month_start
        from bounds
    )
),

counted as (            -- the one version covering the counting day (spans don't overlap, so at most one)
    select
        m.month_start,
        v.*
    from months m
    join versions v
      on m.month_start + {{ counting_day - 1 }} between v.effective_from and v.effective_to
),

days as (               -- days covered in the month across ALL versions (for fractional member months)
    select
        m.month_start,
        v.member_key,
        sum(datediff('day', greatest(v.effective_from, m.month_start), least(v.effective_to, m.month_end)) + 1) as covered_days,
        max(datediff('day', m.month_start, m.month_end) + 1)                                                as days_in_month
    from months m
    join versions v
      on v.effective_from <= m.month_end and v.effective_to >= m.month_start
    group by 1, 2
)

select
    c.member_key || '|' || cast(c.month_start as varchar)   as member_month_key,
    c.month_start,
    c.member_sk,
    c.member_key,
    c.client_id,
    c.group_id,
    c.plan_id,
    c.relationship,
    d.covered_days,
    round(d.covered_days / d.days_in_month, 4)              as fractional_member_month,
    1                                                       as member_month       -- additive measure: sum() = member months
from counted c
join days d
  on d.member_key = c.member_key and d.month_start = c.month_start