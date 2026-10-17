-- Silver: transactions that failed a hard rule. Excluded from fills, kept for review and reprocessing.
select
    transaction_id,
    transaction_code,
    fill_key,
    quarantine_reasons,
    ndc_raw,
    date_of_service,
    days_supply,
    _load_date,
    _source_file,
    current_timestamp as quarantined_at
from {{ ref('int_pharmacy_claims__typed') }}
where is_quarantined