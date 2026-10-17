-- Bronze: 834-style roster rows as received (adds, changes and duplicates included).
with src as (
    select * from {{ source('raw', 'eligibility') }}
)

select
    trim(cardholder_id)           as cardholder_id,
    trim(person_code)             as person_code,
    trim(relationship_code)       as relationship_code,
    first_name                    as first_name_raw,      -- left untrimmed on purpose: silver cleans names
    last_name                     as last_name_raw,
    trim(date_of_birth)           as date_of_birth_raw,   -- mixed formats arrive here
    upper(trim(gender))           as gender,
    trim(zip_code)                as zip_code,
    trim(client_id)               as client_id,
    trim(group_id)                as group_id,
    trim(plan_id)                 as plan_id,
    trim(coverage_start_date)     as coverage_start_date,
    trim(coverage_end_date)       as coverage_end_date,
    trim(maintenance_type_code)   as maintenance_type_code,
    load_date                     as _load_date,
    filename                      as _source_file,
    file_loaded_at                as _file_loaded_at
from src