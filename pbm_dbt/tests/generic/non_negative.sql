-- Class 5: a custom GENERIC test. Write once, attach to any column in YAML:
--   data_tests: [non_negative]
-- dbt passes model + column_name; the test fails if the query returns any row.
{% test non_negative(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} < 0
{% endtest %}
