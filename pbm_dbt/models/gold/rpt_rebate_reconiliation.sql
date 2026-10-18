-- Gold report: rebate reconciliation. GRAIN: one row per rebate quarter x NDC (rebate-eligible drugs).
--   expected rebate = units dispensed (from paid claims) x contracted rebate per unit
--   gap             = expected - invoiced  (positive = under-invoiced: money left on the table)
-- Trust checks before anyone acts on a gap: quarter_closed, claims_coverage_pct -> recon_confidence
with claims_window as (
    select min(date_of_service) as first_dos, max(date_of_service) as last_dos
    from {{ ref('fct_pharmacy_claim') }}
),

utilization as (
    select
        year(f.date_of_service) || 'Q' || quarter(f.date_of_service)   as rebate_quarter,
        f.ndc11,
        count(*)                                                       as paid_fills,
        sum(f.quantity_dispensed)                                      as units_dispensed
    from {{ ref('fct_pharmacy_claim') }} f
    join {{ ref('dim_drug') }} d on d.drug_sk = f.drug_sk
    where d.is_rebate_eligible
    group by all
),

joined as (
    select
        coalesce(u.rebate_quarter, i.rebate_quarter)                   as rebate_quarter,
        coalesce(u.ndc11, i.ndc11)                                     as ndc11,
        coalesce(u.paid_fills, 0)                                      as paid_fills,
        coalesce(u.units_dispensed, 0)                                 as units_dispensed,
        coalesce(i.invoiced_units, 0)                                  as invoiced_units,
        i.rebate_per_unit,
        coalesce(i.invoiced_amount, 0)                                 as invoiced_amount,
        i.invoice_status
    from utilization u
    full outer join {{ ref('int_rebates') }} i
      on i.rebate_quarter = u.rebate_quarter and i.ndc11 = u.ndc11
),

recon as (
    select
        j.*,
        d.drug_name,
        make_date(cast(left(j.rebate_quarter, 4) as integer), (cast(right(j.rebate_quarter, 1) as integer) - 1) * 3 + 1, 1) as quarter_start,
        round(j.units_dispensed * j.rebate_per_unit, 2)                                as expected_rebate,
        round(j.units_dispensed * j.rebate_per_unit, 2) - j.invoiced_amount            as rebate_gap,
        case
            when j.invoiced_units = 0 and j.units_dispensed > 0 then 'not invoiced'
            when j.units_dispensed = 0 and j.invoiced_units > 0 then 'invoiced, no claims'
            when abs(j.units_dispensed - j.invoiced_units) <= 0.02 * j.units_dispensed then 'matched (within 2%)'
            when j.units_dispensed > j.invoiced_units then 'under-invoiced'
            else 'over-invoiced (dispute risk)'
        end                                                                            as recon_status
    from joined j
    left join {{ ref('dim_drug') }} d on d.ndc11 = j.ndc11
),

trust as (
    select
        r.*,
        cast(r.quarter_start + interval 3 month - interval 1 day as date) < w.last_dos          as quarter_closed,
        round(
            (datediff('day', greatest(r.quarter_start, w.first_dos),
                             least(cast(r.quarter_start + interval 3 month - interval 1 day as date), w.last_dos)) + 1)
            / (datediff('day', r.quarter_start, cast(r.quarter_start + interval 3 month - interval 1 day as date)) + 1.0), 3
        )                                                                                         as claims_coverage_pct
    from recon r
    cross join claims_window w
)

select
    rebate_quarter, ndc11, drug_name, paid_fills, units_dispensed, invoiced_units,
    units_dispensed - invoiced_units as unit_variance,
    rebate_per_unit, expected_rebate, invoiced_amount, rebate_gap, invoice_status,
    recon_status, quarter_closed, claims_coverage_pct,
    case
        when not quarter_closed then 'wait: quarter still open'
        when claims_coverage_pct >= 1 then 'conclusive'
        -- missing claims can only make dispensed units LOOK smaller, so under-billing is still provable
        when recon_status in ('under-invoiced', 'not invoiced') then 'conclusive (lower bound: gap is at least this big)'
        else 'inconclusive: warehouse is missing part of the quarter''s claims'
    end as recon_confidence
from trust