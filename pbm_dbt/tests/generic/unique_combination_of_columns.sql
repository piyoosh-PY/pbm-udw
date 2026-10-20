-- Class 5: GRAIN test for a model whose key is several columns (same idea as dbt_utils.unique_combination_of_columns,
-- written by hand so you can explain it). Attach at MODEL level:
--   data_tests:
--     - unique_combination_of_columns:
--         arguments: {combination_of_columns: [client_id, plan_id, service_month]}
{% test unique_combination_of_columns(model, combination_of_columns) %}
select {{ combination_of_columns | join(', ') }}, count(*) as rows_per_key
from {{ model }}
group by {{ combination_of_columns | join(', ') }}
having count(*) > 1
{% endtest %}
