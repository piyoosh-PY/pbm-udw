-- Gold: member dimension, SCD Type 2 on BUSINESS time.
-- Grain: one row per member per coverage version (effective_from .. effective_to).
-- A plan change creates a new row with a new member_sk, so facts keep the plan that was true on the date of service.
-- PHI: HIPAA "minimum necessary". Client reporting needs no names, so names stay in silver; zip is cut to 3 digits.
-- Special rows:  '-1' = unknown member (claim arrived before any eligibility: orphan)
--                '-2' = known member, but no coverage on the date of service (e.g. paid after a retro-termination)
with spans as (
    select * from {{ ref('int_member_coverage_spans') }}
),

demographics as (            -- current demographics (SCD1): a corrected birth date should fix history too
    select member_key, cardholder_id, person_code, relationship_code, date_of_birth, gender, zip_code
    from {{ ref('int_eligibility') }}
)

select
    md5(s.member_key || '|' || cast(s.effective_from as varchar))   as member_sk,
    s.member_key,
    d.cardholder_id,
    d.person_code,
    case d.relationship_code
        when '18' then 'subscriber'
        when '01' then 'spouse'
        when '19' then 'child'
        else 'other'
    end                                                             as relationship,
    d.date_of_birth,
    d.gender,
    left(d.zip_code, 3)                                             as zip3,
    s.client_id,
    s.group_id,
    s.plan_id,
    s.version_number,
    s.effective_from,
    s.effective_to,
    s.effective_to = date '9999-12-31'                              as is_open_ended,
    s.is_current_version
from spans s
left join demographics d on d.member_key = s.member_key

union all

select '-1', null, null, null, 'unknown', null, null, null, null, null, null, null,
       date '1900-01-01', date '9999-12-31', true, true
union all
select '-2', null, null, null, 'no coverage on date of service', null, null, null, null, null, null, null,
       date '1900-01-01', date '9999-12-31', true, true