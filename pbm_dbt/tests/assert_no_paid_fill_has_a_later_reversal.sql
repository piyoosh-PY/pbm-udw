-- A fill must not look paid in silver if a valid reversal (B2) for it arrived later.
-- This is the late-arriving-data test: it fails when an incremental model can't "un-pay" a fill.
select
    f.fill_key,
    f.final_transaction_id,
    f.submitted_at        as fill_submitted_at,
    t.transaction_id      as later_reversal_id,
    t.submitted_at        as reversal_submitted_at,
    t._load_date          as reversal_load_date
from {{ ref('int_pharmacy_fills') }} f
join {{ ref('int_pharmacy_claims__typed') }} t
  on t.fill_key = f.fill_key
 and t.transaction_code = 'B2'
 and not t.is_quarantined
 and t.submitted_at > f.submitted_at
where f.final_transaction_code in ('B1', 'B3')