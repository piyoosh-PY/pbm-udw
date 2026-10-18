-- Silver step 2: reversal netting. Grain: one row per fill_key, with fill_status = paid | reversed | rejected.
-- Incremental pattern: find the fills touched by this run, recompute them from their FULL transaction history,
-- and replace those rows (delete+insert on fill_key). Reversed fills stay as tombstones, so a late B2 can
-- overwrite a fill that was paid in an earlier run. Downstream models filter fill_status = 'paid'.
{{
    config(
        materialized='incremental',
        incremental_strategy='delete+insert',
        unique_key='fill_key',
        on_schema_change='fail'
    )
}}

with valid as (
    select * from {{ ref('int_pharmacy_claims__typed') }}
    where not is_quarantined
),

{% if is_incremental() %}
touched_fills as (   -- fills with at least one transaction (re)processed since this model last ran
    select distinct fill_key
    from valid
    where _processed_at > (select max(_processed_at) from {{ this }})
),
{% endif %}

history as (         -- every valid transaction of those fills, old and new
    select v.*
    from valid v
    {% if is_incremental() %}
    where v.fill_key in (select fill_key from touched_fills)
    {% endif %}
)

{{ net_pharmacy_fills('history') }}