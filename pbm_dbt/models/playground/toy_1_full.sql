-- Approach 1: FULL REFRESH. Drop and rebuild from the source every run.
{{ config(materialized='table', tags=['playground'], schema='playground') }}
select * from {{ ref('toy_orders') }}