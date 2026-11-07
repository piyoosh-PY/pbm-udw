{% test is_between( model,column_name,min_value,max_value) %}

-- Fails for every row where the value falls outside [min_value, max_value].
-- NULLs are allowed here (a ratio with a zero denominator is NULL by design); use not_null to forbid them.
select {{column_name}}
from {{ model }}
where {{ column_name }} is not null
and ( {{ column_name }} < {{ min_value }} 
or {{ column_name }} > {{ max_value }} )

{% endtest %}