
-- Silver step 2: reversal netting. Grain: one row per FINAL PAID fill (fill_key).
-- Latest transaction per fill wins: B1/B3 + paid = dispensed; B2 latest = reversed (fill disappears); R = never paid.
with valid as (
    select * from {{ ref('int_pharmacy_claims__typed') }}
    where not is_quarantined
),
ranked as (
    select
        *,
        row_number() over (partition by fill_key order by submitted_at desc, transaction_id desc) as txn_rank,
        count(*)     over (partition by fill_key)                                                 as transaction_count,
        bool_or(transaction_code = 'B2') over (partition by fill_key)                             as was_reversed
    from valid
)
select
    fill_key,
    transaction_id                    as final_transaction_id,
    transaction_code                  as final_transaction_code,
    transaction_count,
    was_reversed,
    transaction_code = 'B3'           as was_rebilled,
    pharmacy_npi,
    rx_number,
    fill_number,
    date_of_service,
    member_key,
    cardholder_id,
    person_code,
    ndc11,
    prescriber_npi,
    quantity_dispensed,
    days_supply,
    daw_code,
    ingredient_cost_paid,
    dispensing_fee_paid,
    patient_pay_amount,
    plan_paid_amount,
    submitted_at,
    dq_ndc_not_in_reference,
    dq_orphan_member,
    dq_invalid_prescriber_npi,
    _load_date
from ranked
where txn_rank = 1
  and transaction_code in ('B1', 'B3')
  and response_status = 'P'