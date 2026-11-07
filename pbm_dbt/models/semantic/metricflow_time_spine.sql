-- One row per day. MetricFlow uses this to aggregate metrics to any time grain (day/week/month/quarter)
-- and to fill gaps in time. Range covers the data window with room to spare.
{{ config(materialized='table') }}

select cast(range as date) as date_day
from range(date '2025-01-01', date '2027-12-31', interval 1 day)