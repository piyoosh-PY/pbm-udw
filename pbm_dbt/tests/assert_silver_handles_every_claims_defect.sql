-- Defect coverage: for every claims defect the generator injected, silver must show the expected effect.
-- The manifest is our "golden answer". Passes when it returns zero rows.
with manifest as (
    select defects from read_json('{{ var("raw_root") }}/_manifest/load_date=*/defects.json')
),

expected as (
              select 'exact duplicates removed'        as check_name, sum(defects.exact_duplicate_claim_row.count)              as expected from manifest
    union all select 'future DOS quarantined',          sum(defects.future_date_of_service.count)                     from manifest
    union all select 'bad days supply quarantined',     sum(defects.days_supply_out_of_range.count)                   from manifest
    union all select '10-digit NDCs normalized',        sum(defects.ndc_10_digit_hyphenated.count)                    from manifest
    union all select 'dollar amounts repaired',         sum(defects.amount_with_dollar_sign.count)                    from manifest
    union all select 'fills reversed (not rebilled)',   sum(defects.reversal_b2.count) - sum(defects.rebill_b3.count) from manifest
    union all select 'fills rebilled',                  sum(defects.rebill_b3.count)                                  from manifest
    union all select 'orphan members flagged',          sum(defects.orphan_member.count)                              from manifest
    union all select 'invalid prescriber NPIs flagged', sum(defects.invalid_prescriber_npi.count)                     from manifest
    union all select 'unknown NDCs flagged',            sum(defects.ndc_not_in_drug_reference.count)                  from manifest
),

bronze as (select * from {{ ref('stg_pharmacy_claims') }}),
typed  as (select * from {{ ref('int_pharmacy_claims__typed') }}),
fills  as (select * from {{ ref('int_pharmacy_fills') }}),

actual as (
              select 'exact duplicates removed' as check_name, (select count(*) from bronze) - (select count(*) from typed) as actual
    union all select 'future DOS quarantined',          count(*) from typed where list_contains(quarantine_reasons, 'future_date_of_service')
    union all select 'bad days supply quarantined',     count(*) from typed where list_contains(quarantine_reasons, 'days_supply_invalid')
    union all select '10-digit NDCs normalized',        count(*) from typed where ndc_raw like '%-%' and length(ndc11) = 11
    union all select 'dollar amounts repaired',         count(*) from typed
                                                        where ingredient_cost_paid is not null
                                                          and transaction_id in (select transaction_id from bronze where ingredient_cost_paid like '$%')
    union all select 'fills reversed (not rebilled)',   count(*) from (
                                                            select fill_key from typed where not is_quarantined
                                                            qualify row_number() over (partition by fill_key order by submitted_at desc, transaction_id desc) = 1
                                                                and transaction_code = 'B2')
    union all select 'fills rebilled',                  count(*) from fills where was_rebilled
    union all select 'orphan members flagged',          count(*) from typed where dq_orphan_member
    union all select 'invalid prescriber NPIs flagged', count(*) from typed where dq_invalid_prescriber_npi
    union all select 'unknown NDCs flagged',            count(*) from typed where dq_ndc_not_in_reference
)

select e.check_name, e.expected, a.actual
from expected e
join actual a using (check_name)
where e.expected <> a.actual