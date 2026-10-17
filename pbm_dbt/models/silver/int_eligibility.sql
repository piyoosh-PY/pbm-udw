-- Silver: one current record per member (cardholder + person code).
-- Latest-wins dedup: a 001 change record loaded later replaces the 021 add; exact duplicates collapse.
with typed as (
    select
        cardholder_id,
        person_code,
        cardholder_id || '-' || person_code                     as member_key,
        relationship_code,
        upper(left(trim(first_name_raw), 1)) || lower(substr(trim(first_name_raw), 2)) as first_name,
        upper(left(trim(last_name_raw), 1))  || lower(substr(trim(last_name_raw), 2))  as last_name,
        {{ parse_date_multi('date_of_birth_raw') }}            as date_of_birth,
        gender,
        nullif(zip_code, '')                                   as zip_code,
        client_id,
        group_id,
        plan_id,
        try_cast(coverage_start_date as date)                  as coverage_start_date,
        try_cast(nullif(coverage_end_date, '') as date)        as coverage_end_date,
        maintenance_type_code,
        cast(_file_loaded_at as timestamp)                     as _file_loaded_at,
        _load_date
    from {{ ref('stg_eligibility') }}
)

select
    *,
    coalesce(coverage_end_date < coverage_start_date, false)   as dq_coverage_end_before_start,
    zip_code is null                                           as dq_missing_zip
from typed
qualify row_number() over (
    partition by member_key
    order by _file_loaded_at desc, maintenance_type_code asc   -- tie-breaker: '001' (change) sorts before '021' (add)
) = 1