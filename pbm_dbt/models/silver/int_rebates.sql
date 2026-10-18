-- Silver: manufacturer rebate invoices. Grain: one row per rebate quarter x NDC (latest file wins).
-- Each daily file re-sends the invoice lines with their CURRENT status (INVOICED -> COLLECTED / DISPUTED),
-- so the newest load is the truth for status and amounts.
select
    rebate_quarter,
    ndc11,
    manufacturer,
    try_cast(invoiced_units as decimal(14, 3))      as invoiced_units,
    try_cast(rebate_per_unit as decimal(12, 4))     as rebate_per_unit,
    {{ clean_amount('invoiced_amount') }}           as invoiced_amount,
    status                                          as invoice_status,
    cast(_load_date as date)                        as _load_date,
    _source_file
from {{ ref('stg_rebates') }}
qualify row_number() over (partition by rebate_quarter, ndc11 order by _load_date desc, _source_file desc) = 1