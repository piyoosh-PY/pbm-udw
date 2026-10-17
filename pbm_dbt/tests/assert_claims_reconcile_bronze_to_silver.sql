
-- Reconciliation identity: bronze rows = silver typed rows + duplicates removed,
-- and typed rows = valid rows + quarantined rows. Nothing disappears silently.
with counts as (
    select
        (select count(*) from {{ ref('stg_pharmacy_claims') }})                                      as bronze_rows,
        (select count(distinct transaction_id) from {{ ref('stg_pharmacy_claims') }})                as bronze_distinct_txn,
        (select count(*) from {{ ref('int_pharmacy_claims__typed') }})                               as typed_rows,
        (select count(*) from {{ ref('int_pharmacy_claims__typed') }} where not is_quarantined)      as valid_rows,
        (select count(*) from {{ ref('int_pharmacy_claims__quarantine') }})                          as quarantined_rows
)
select *
from counts
where typed_rows <> bronze_distinct_txn
   or typed_rows <> valid_rows + quarantined_rows