{% macro net_pharmacy_fills(transactions) -%}
    {#-
      Reversal netting, written once and used by the model AND by the full-recompute test.
      Input: any relation/CTE of valid (non-quarantined) transactions.
      Output: one row per fill_key with its final status. Reversed fills are KEPT as tombstones
      (fill_status = 'reversed') so an incremental run can overwrite a previously paid row.
    -#}
    select
        fill_key,
        transaction_id                    as final_transaction_id,
        transaction_code                  as final_transaction_code,
        case
            when transaction_code = 'B2' then 'reversed'
            when response_status = 'R'   then 'rejected'
            else 'paid'
        end                               as fill_status,
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
        _load_date,
        _fill_processed_at                as _processed_at   -- latest time any transaction of this fill was (re)processed
    from (
        select
            *,
            row_number() over (
                partition by fill_key
                order by submitted_at desc,
                         case transaction_code when 'B3' then 3 when 'B2' then 2 else 1 end desc,  -- business precedence on ties
                         transaction_id desc                                                       -- unique last tie-breaker
            )                                                          as txn_rank,
            count(*)                         over (partition by fill_key) as transaction_count,
            bool_or(transaction_code = 'B2') over (partition by fill_key) as was_reversed,
            max(_processed_at)               over (partition by fill_key) as _fill_processed_at
        from {{ transactions }}
    )
    where txn_rank = 1
{%- endmacro %}