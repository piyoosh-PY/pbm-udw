-- Completeness check: every row the sender says it sent must reach bronze, per load.
-- Passes when it returns zero rows.
with manifest as (
    select
        cast(load_date as varchar)                 as load_date,
        cast(row_counts.pharmacy_claims as bigint) as expected_rows
    from read_json('{{ var("raw_root") }}/_manifest/load_date=*/defects.json')
),

actual as (
    select cast(_load_date as varchar) as load_date, count(*) as actual_rows
    from {{ ref('stg_pharmacy_claims') }}
    group by 1
)

select
    coalesce(m.load_date, a.load_date) as load_date,
    m.expected_rows,
    a.actual_rows
from manifest m
full outer join actual a on a.load_date = m.load_date
where coalesce(m.expected_rows, -1) <> coalesce(a.actual_rows, -1)