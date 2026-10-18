-- Silver: one golden record per NPI (survivorship) with a check-digit flag.
-- Rule: keep the most descriptive name (longest), tie-break alphabetically for determinism.
SELECT
    npi,
    entity_type,
    case entity_type when '1' then 'prescriber'
    when '2' then 'pharmacy' end as provider_role,
    name_raw       as provider_name,
    taxonomy_code,
    state,
    {{ is_valid_npi('npi') }} as is_valid_npi,
    count(*) over (partition by npi) as source_record_count

from {{ ref('stg_providers')}}
qualify row_number() over (partition by npi order by length(name_raw) desc, name_raw asc) = 1