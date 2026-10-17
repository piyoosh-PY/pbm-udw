select
    trim(rebate_quarter)    as rebate_quarter,
    trim(ndc11)             as ndc11,
    trim(manufacturer)      as manufacturer,
    trim(invoiced_units)    as invoiced_units,
    trim(rebate_per_unit)   as rebate_per_unit,
    trim(invoiced_amount)   as invoiced_amount,
    upper(trim(status))     as status,
    load_date               as _load_date,
    filename                as _source_file
from {{ source('raw', 'rebates') }}