-- Class 5: a THRESHOLD test. Some bad rows are normal (late eligibility, new NDCs); a spike is not.
-- Returns one row (= fails) when the share of rows matching `condition` is above `max_share`.
--   data_tests:
--     - max_share:
--         arguments: {condition: "drug_sk = '-1'", max_share: 0.02}
--         config: {severity: warn}
{% test max_share(model, condition, max_share) %}
select
    count(*) filter (where {{ condition }})                          as matching_rows,
    count(*)                                                         as total_rows,
    count(*) filter (where {{ condition }}) * 1.0 / nullif(count(*), 0) as share
from {{ model }}
having count(*) filter (where {{ condition }}) * 1.0 / nullif(count(*), 0) > {{ max_share }}
{% endtest %}
