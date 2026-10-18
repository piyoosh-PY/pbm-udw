-- Approach 2: INCREMENTAL APPEND with a watermark. Only rows newer than what I already have; just INSERT them.
{{ config(materialized='incremental', incremental_strategy='append', tags=['playground'], schema='playground') }}
select * from {{ ref('toy_orders') }}
{% if is_incremental() %}
where updated_at > (select max(updated_at) from {{ this }})
{% endif %}