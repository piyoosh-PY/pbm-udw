-- Class 5: the incremental fact must never keep a fill that silver now says is reversed or rejected.
-- This is the test that proves the post_hook (delete tombstones) works: delete+insert alone cannot remove them.
select f.fill_key, s.fill_status, f._gold_loaded_at
from {{ ref('fct_pharmacy_claim') }} f
join {{ ref('int_pharmacy_fills') }} s on s.fill_key = f.fill_key
where s.fill_status <> 'paid'
