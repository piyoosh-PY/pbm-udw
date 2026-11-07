{% test unique_combination(model,combinations_of_columns) %}

-- The grain test for any table whose grain is more than one column.
-- Fails with each key combination that appears more than once (a fan-out or a duplicate load).
select {{ combinations_of_columns | join (',')}}, count(*) as n_rows
from {{model}}
group by {{ combinations_of_columns | join (', ') }}
having count(*) > 1

{% endtest %}