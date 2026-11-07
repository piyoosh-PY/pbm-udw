-- Defect coverage: for every claims defect the generator injected, silver must show the expected effect.
-- The manifest is our "golden answer". Passes when it returns zero rows.
with manifest as (
    -- read_json_objects keeps each manifest as raw JSON (not a typed struct), so a defect type that
    -- doesn't exist yet (e.g. late reversals on the first load) extracts as NULL instead of a bind error
    select json -> '$.defects' as d
    from read_json_objects('{{ var("raw_root") }}/_manifest/load_date=*/defects.json', format = 'auto')
),

counts as (
    select
        coalesce(sum(cast(d ->> '$.exact_duplicate_claim_row.count'     as integer)), 0) as exact_duplicate_claim_row,
        coalesce(sum(cast(d ->> '$.future_date_of_service.count'        as integer)), 0) as future_date_of_service,
        coalesce(sum(cast(d ->> '$.days_supply_out_of_range.count'      as integer)), 0) as days_supply_out_of_range,
        coalesce(sum(cast(d ->> '$.ndc_10_digit_hyphenated.count'       as integer)), 0) as ndc_10_digit_hyphenated,
        coalesce(sum(cast(d ->> '$.amount_with_dollar_sign.count'       as integer)), 0) as amount_with_dollar_sign,
        coalesce(sum(cast(d ->> '$.reversal_b2.count'                   as integer)), 0) as reversal_b2,
        coalesce(sum(cast(d ->> '$.rebill_b3.count'                     as integer)), 0) as rebill_b3,
        coalesce(sum(cast(d ->> '$.late_reversal_prior_load.count'      as integer)), 0) as late_reversal_prior_load,
        coalesce(sum(cast(d ->> '$.orphan_member.count'                 as integer)), 0) as orphan_member,
        coalesce(sum(cast(d ->> '$.late_eligibility_prior_orphan.count' as integer)), 0) as late_eligibility_prior_orphan,
        coalesce(sum(cast(d ->> '$.invalid_prescriber_npi.count'        as integer)), 0) as invalid_prescriber_npi,
        coalesce(sum(cast(d ->> '$.ndc_not_in_drug_reference.count'     as integer)), 0) as ndc_not_in_drug_reference
    from manifest
),

expected as (
              select 'exact duplicates removed'        as check_name, exact_duplicate_claim_row                             as expected from counts
    union all select 'future DOS quarantined',          future_date_of_service                                                  from counts
    union all select 'bad days supply quarantined',     days_supply_out_of_range                                                from counts
    union all select '10-digit NDCs normalized',        ndc_10_digit_hyphenated                                                 from counts
    union all select 'dollar amounts repaired',         amount_with_dollar_sign                                                 from counts
    union all select 'fills reversed (not rebilled)',   reversal_b2 - rebill_b3 + late_reversal_prior_load                      from counts
    union all select 'fills rebilled',                  rebill_b3                                                               from counts
    union all select 'orphan members flagged',          orphan_member - late_eligibility_prior_orphan                           from counts
    union all select 'invalid prescriber NPIs flagged', invalid_prescriber_npi                                                  from counts
    union all select 'unknown NDCs flagged',            ndc_not_in_drug_reference                                               from counts
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
    union all select 'fills reversed (not rebilled)',   count(*) from fills where fill_status = 'reversed'
    union all select 'fills rebilled',                  count(*) from fills where was_rebilled
    union all select 'orphan members flagged',          count(*) from typed where dq_orphan_member
    union all select 'invalid prescriber NPIs flagged', count(*) from typed where dq_invalid_prescriber_npi
    union all select 'unknown NDCs flagged',            count(*) from typed where dq_ndc_not_in_reference
)

select e.check_name, e.expected, a.actual
from expected e
join actual a using (check_name)
where e.expected <> a.actual