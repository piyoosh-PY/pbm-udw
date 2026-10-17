-- Silver: typed drug reference, one row per 11-digit NDC.

select
    ndc11,
    drug_name,
    gpi14,
    left(gpi14, 2)                              as gpi_drug_group,
    left(gpi14, 4)                              as gpi_drug_class,
    multi_source_code,
    multi_source_code = 'Y'                     as is_generic,
    is_specialty = 'true'                       as is_specialty,
    cast(awp_unit_price as decimal(12, 4))      as awp_unit_price,
    labeler_name

from {{ ref ('stg_drug_reference')}}
qualify row_number() over (PARTITION BY ndc11 order by _load_date)=1