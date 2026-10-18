-- Incremental correctness: the incrementally maintained fills table must equal a from-scratch recompute
-- of the same netting logic over ALL valid transactions. Any row in one side but not the other is a failure.
-- (Same macro on both sides, so this tests the incremental mechanics, not the business rule.)
with incremental as (
    select fill_key, final_transaction_id, fill_status, plan_paid_amount, dq_orphan_member
    from {{ ref('int_pharmacy_fills') }}
),

full_recompute as (
    select fill_key, final_transaction_id, fill_status, plan_paid_amount, dq_orphan_member
    from (
        {{ net_pharmacy_fills("(select * from " ~ ref('int_pharmacy_claims__typed') ~ " where not is_quarantined)") }}
    )
)

(select 'only in incremental' as side, * from incremental except select 'only in incremental', * from full_recompute)
union all
(select 'only in full recompute' as side, * from full_recompute except select 'only in full recompute', * from incremental)