select
    trim(npi)            as npi,
    trim(entity_type)    as entity_type,
    trim(name)           as name_raw,
    trim(taxonomy_code)  as taxonomy_code,
    upper(trim(state))   as state,
    load_date            as _load_date,
    filename             as _source_file
from {{ source('raw', 'providers') }}