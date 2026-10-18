-- Gold: pharmacy claim fact. GRAIN: one row per final PAID fill (reversed and rejected fills excluded).
-- Point-in-time join: the member version whose coverage contains the date of service, so a plan change
-- or a retro-termination never rewrites which plan paid a past fill.
-- Every foreign key is filled: unmatched rows point at special dimension rows (-1 / -2), never NULL.
with fills as (
    select * from {{ ref('int_pharmacy_fills') }}
    where fill_status = 'paid'
),

member_versions as (
    select * from {{ ref('dim_member') }}
    where member_key is not null                     -- real versions only, not the special rows
),

known_members as (       -- every member with ANY eligibility record, including never-effective / invalid spans
    select distinct member_key from {{ ref('int_eligibility') }}
    --  select distinct member_key from member_versions
)

select
    -- keys
    f.fill_key,                                                          -- degenerate dimension (no dim table of its own)
    case
        when mv.member_sk is not null then mv.member_sk                  -- covered on the date of service
        when km.member_key is not null then '-2'                         -- member exists, but not covered that day
        else '-1'                                                        -- no eligibility at all (orphan)
    end                                                                  as member_sk,
    coalesce(d.drug_sk, '-1')                                            as drug_sk,
    coalesce(ph.provider_sk, '-1')                                       as pharmacy_sk,
    coalesce(pr.provider_sk, '-1')                                       as prescriber_sk,
    f.date_of_service,
    cast(date_trunc('month', f.date_of_service) as date)                 as service_month,

    -- natural keys kept for tracing back to silver/bronze
    f.member_key,
    f.ndc11,
    f.rx_number,
    f.final_transaction_id,
    f.final_transaction_code,
    f.was_rebilled,
    f.was_reversed,

    -- measures (additive)
    f.quantity_dispensed,
    f.days_supply,
    greatest(1, round(f.days_supply / 30.0))::integer                    as adjusted_rx_count,  -- 30-day equivalents: a 90-day fill = 3
    f.ingredient_cost_paid,
    f.dispensing_fee_paid,
    f.ingredient_cost_paid + f.dispensing_fee_paid                       as gross_cost,
    f.patient_pay_amount,
    f.plan_paid_amount,

    -- flags
    mv.member_sk is not null                                             as is_covered_on_dos,
    f.dq_orphan_member,
    f.dq_ndc_not_in_reference,
    f.dq_invalid_prescriber_npi

from fills f
left join member_versions mv
       on mv.member_key = f.member_key
      and f.date_of_service between mv.effective_from and mv.effective_to
left join known_members km
       on km.member_key = f.member_key
left join {{ ref('dim_drug') }} d
       on d.ndc11 = f.ndc11
left join {{ ref('dim_provider') }} ph
       on ph.npi = f.pharmacy_npi and ph.provider_role = 'pharmacy'
left join {{ ref('dim_provider') }} pr
       on pr.npi = f.prescriber_npi and pr.provider_role = 'prescriber'