select
    trim(ndc11)                    as ndc11,
    trim(drug_name)                as drug_name,
    trim(gpi14)                    as gpi14,
    upper(trim(multi_source_code)) as multi_source_code,
    lower(trim(is_specialty))      as is_specialty,
    trim(awp_unit_price)           as awp_unit_price,
    trim(labeler_name)             as labeler_name,
    load_date                      as _load_date,
    filename                       as _source_file
from {{ source('raw', 'drug_reference') }}