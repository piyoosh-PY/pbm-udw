-- A fill pointing at a real member version must have its date of service inside that version's coverage.
select f.fill_key, f.date_of_service, m.effective_from, m.effective_to
from {{ ref('fct_pharmacy_claim') }} f
join {{ ref('dim_member') }} m on m.member_sk = f.member_sk
where m.member_key is not null
  and f.date_of_service not between m.effective_from and m.effective_to