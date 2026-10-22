select f.fill_key, s.fill_status, f._gold_loaded_at
from {{ ref('fct_pharmacy_claim') }} f
join {{ ref('int_pharmacy_fills') }} s on s.fill_key = f.fill_key
where s.fill_status <> 'paid'