-- Approach 4: INCREMENTAL MERGE with a LOOKBACK window. Re-read the last 1 day too, so late rows are caught.
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_id', tags=['playground'], schema='playground') }}
select * from {{ ref('toy_orders') }}
{% if is_incremental() %}
where updated_at > (select max(updated_at) from {{ this }}) - interval 1 day
{% endif %}