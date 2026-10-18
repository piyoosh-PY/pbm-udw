-- Gold: drug dimension. Grain: one row per 11-digit NDC, plus one '-1' Unknown row
-- so fills whose NDC is missing from the drug file still join (and stay visible) instead of vanishing.
select
    md5(ndc11)                                       as drug_sk,
    ndc11,
    drug_name,
    gpi14,
    gpi_drug_group,
    gpi_drug_class,
    multi_source_code,
    case multi_source_code
        when 'Y' then 'generic'
        when 'M' then 'multi-source brand'
        when 'O' then 'brand, generic available'
        when 'N' then 'single-source brand'
    end                                              as brand_generic_category,
    is_generic,
    is_specialty,
    multi_source_code in ('N', 'O')                  as is_rebate_eligible,
    awp_unit_price,
    labeler_name
from {{ ref('int_drugs') }}

union all

select
    '-1', null, 'Unknown drug (NDC not in drug file)', null, null, null, null, 'unknown',
    null, null, false, null, null