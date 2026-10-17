
-- Silver step 1: one row per transaction (exact duplicates removed), typed, repaired, and checked.
-- Grain: transaction_id. Every data-quality rule becomes a dq_ column so nothing is dropped silently.
with deduped as (
    select *
    from {{ ref('stg_pharmacy_claims') }}
    qualify row_number() over (
        partition by transaction_id
        order by _file_loaded_at desc, _source_file desc
    ) = 1
),

typed as (
    select
        transaction_id,
        transaction_code,
        response_status,
        pharmacy_npi || '|' || rx_number || '|' || fill_number || '|' || date_of_service as fill_key,
        pharmacy_npi,
        rx_number,
        try_cast(fill_number as integer)              as fill_number,
        try_cast(date_of_service as date)             as date_of_service,
        cardholder_id,
        person_code,
        cardholder_id || '-' || person_code           as member_key,
        ndc_raw,
        {{ normalize_ndc('ndc_raw') }}                as ndc11,
        prescriber_npi,
        try_cast(quantity_dispensed as decimal(12, 3)) as quantity_dispensed,
        try_cast(days_supply as integer)              as days_supply,
        daw_code,
        {{ clean_amount('ingredient_cost_paid') }}    as ingredient_cost_paid,
        {{ clean_amount('dispensing_fee_paid') }}     as dispensing_fee_paid,
        {{ clean_amount('patient_pay_amount') }}      as patient_pay_amount,
        {{ clean_amount('plan_paid_amount') }}        as plan_paid_amount,
        try_cast(submitted_at as timestamp)           as submitted_at,
        _load_date,
        _source_file,
        cast(_file_loaded_at as timestamp)            as _file_loaded_at
    from deduped
),
checked as (
    select
        t.*,
        -- hard rules (row is quarantined)
        t.date_of_service is null                                      as dq_dos_unparseable,
        coalesce(t.date_of_service > t._load_date, false)              as dq_future_date_of_service,
        coalesce(t.days_supply not between 1 and 365, true)            as dq_days_supply_invalid,
        (t.ingredient_cost_paid is null or t.dispensing_fee_paid is null
            or t.patient_pay_amount is null or t.plan_paid_amount is null) as dq_amount_unparseable,
        t.ndc11 is null                                                as dq_ndc_unrecognized,
        -- soft rules (row is kept and flagged)
        d.ndc11 is null and t.ndc11 is not null                        as dq_ndc_not_in_reference,
        e.member_key is null                                           as dq_orphan_member,
        not {{ is_valid_npi('t.prescriber_npi') }}                     as dq_invalid_prescriber_npi
    from typed t
    left join {{ ref('int_drugs') }} d on d.ndc11 = t.ndc11
    left join {{ ref('int_eligibility') }} e on e.member_key = t.member_key
)
select
    *,
    list_filter(
        [
            case when dq_dos_unparseable then 'dos_unparseable' end,
            case when dq_future_date_of_service then 'future_date_of_service' end,
            case when dq_days_supply_invalid then 'days_supply_invalid' end,
            case when dq_amount_unparseable then 'amount_unparseable' end,
            case when dq_ndc_unrecognized then 'ndc_unrecognized' end
        ],
        lambda x: x is not null
    )                                                                  as quarantine_reasons,
    (dq_dos_unparseable or dq_future_date_of_service or dq_days_supply_invalid
        or dq_amount_unparseable or dq_ndc_unrecognized)               as is_quarantined
from checked