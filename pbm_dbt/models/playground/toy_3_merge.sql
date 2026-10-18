-- Approach 3: INCREMENTAL MERGE with a watermark. Same filter, but UPSERT by order_id.
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_id', tags=['playground'], schema='playground') }}
select * from {{ ref('toy_orders') }}
{% if is_incremental() %}
where updated_at > (select max(updated_at) from {{ this }})
{% endif %}