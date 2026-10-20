-- Silver: effective-dated coverage spans per member, built from the SCD2 snapshot.
-- Two clocks (bitemporal):
--   effective_from / effective_to  = BUSINESS time: when the coverage was true (from 834 effective dates)
--   known_from / known_to          = SYSTEM time:   when the warehouse learned it (snapshot dbt_valid_from/to)
-- Claims are matched on business time: which plan covered the member ON the date of service?
with versions as (
    select
        member_key,
        client_id,
        group_id,
        plan_id,
        coverage_start_date,
        coverage_end_date,
        maintenance_type_code,
        maintenance_effective_date,
        dbt_valid_from                                         as known_from,
        dbt_valid_to                                           as known_to,
        row_number() over (partition by member_key order by dbt_valid_from) as version_number
    from {{ ref('snap_member_eligibility') }}
    where not is_never_effective and not dq_coverage_end_before_start   -- no real coverage to match against
),

dated as (
    select
        *,
        case
            when version_number = 1 then coverage_start_date             -- first version: history before it is unknown
            else greatest(maintenance_effective_date, coverage_start_date)
        end                                                    as effective_from
    from versions
),

spanned as (
    select
        member_key,
        version_number,
        client_id,
        group_id,
        plan_id,
        maintenance_type_code,
        effective_from,
        least(
            coalesce(lead(effective_from) over (partition by member_key order by version_number) - 1, date '9999-12-31'),
            coalesce(coverage_end_date, date '9999-12-31')
        )                                                      as effective_to,
        known_from,
        known_to,
        known_to = timestamp '9999-12-31'                      as is_current_version
    from dated
)

-- Class 5 fix (found by the Oct 3 load): a brand-new add (021) followed by a RETRO change (001) dated before
-- the coverage start makes v2 begin on the same day as v1, so v1 collapses to an empty span (effective_to < effective_from).
-- That version was never in force for a single day: drop it. Without this, dim_member got two rows with the same
-- member_sk (md5 of member_key | effective_from) and the unique test failed.
select * from spanned
where effective_to >= effective_from
