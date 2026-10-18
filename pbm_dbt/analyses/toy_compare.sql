-- All four approaches side by side, one row per order. toy_1_full is the source of truth.
-- A cell like "placed $50 + cancelled $50" means the table holds TWO rows for that order.
with all_rows as (
              select 'full'     as approach, * from {{ ref('toy_1_full') }}
    union all select 'append',   * from {{ ref('toy_2_append') }}
    union all select 'merge',    * from {{ ref('toy_3_merge') }}
    union all select 'lookback', * from {{ ref('toy_4_merge_lookback') }}
)
select
    order_id,
    string_agg(status || ' $' || amount, ' + ' order by updated_at) filter (where approach = 'full')     as full_refresh,
    string_agg(status || ' $' || amount, ' + ' order by updated_at) filter (where approach = 'append')   as append_watermark,
    string_agg(status || ' $' || amount, ' + ' order by updated_at) filter (where approach = 'merge')    as merge_watermark,
    string_agg(status || ' $' || amount, ' + ' order by updated_at) filter (where approach = 'lookback') as merge_lookback
from all_rows
group by order_id
order by order_id