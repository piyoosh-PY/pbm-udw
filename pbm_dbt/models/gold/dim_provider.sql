-- Gold: provider dimension. Grain: one row per NPI, plus '-1' Unknown.
-- Role-playing dimension: the fact joins it TWICE, once as the pharmacy and once as the prescriber.
select
    md5(npi)                 as provider_sk,
    npi,
    provider_role,
    provider_name,
    taxonomy_code,
    state,
    is_valid_npi
from {{ ref('int_providers') }}

union all

select '-1', null, 'unknown', 'Unknown provider (NPI not in registry)', null, null, null