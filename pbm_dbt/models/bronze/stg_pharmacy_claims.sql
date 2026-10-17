-- Bronze: one row per transaction exactly as received (B1 / B2 / B3, duplicates included).
-- Rename + trim + standardize code casing only. No casting, filtering or business logic.
with src as (
    select * from {{ source('raw', 'pharmacy_claims') }}
)

select
    -- transaction identity
    trim(transaction_id)              as transaction_id,
    upper(trim(transaction_code))     as transaction_code,
    upper(trim(response_status))      as response_status,

    -- fill key (pharmacy + rx + fill + date of service)
    trim(pharmacy_npi)                as pharmacy_npi,
    trim(rx_number)                   as rx_number,
    trim(fill_number)                 as fill_number,
    trim(date_of_service)             as date_of_service,

    -- member, drug, prescriber (raw text; cleaned in silver)
    trim(cardholder_id)               as cardholder_id,
    trim(person_code)                 as person_code,
    trim(ndc)                         as ndc_raw,
    trim(prescriber_npi)              as prescriber_npi,

    -- quantities and money (raw text; cleaned in silver)
    trim(quantity_dispensed)          as quantity_dispensed,
    trim(days_supply)                 as days_supply,
    trim(daw_code)                    as daw_code,
    trim(ingredient_cost_paid)        as ingredient_cost_paid,
    trim(dispensing_fee_paid)         as dispensing_fee_paid,
    trim(patient_pay_amount)          as patient_pay_amount,
    trim(plan_paid_amount)            as plan_paid_amount,
    trim(submitted_at)                as submitted_at,

    -- lineage metadata: where every row came from
    load_date                         as _load_date,
    filename                          as _source_file,
    file_loaded_at                    as _file_loaded_at
from src