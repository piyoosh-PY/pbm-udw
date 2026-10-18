-- Business identity on every paid fill: ingredient cost + dispensing fee = patient pay + plan paid (1 cent tolerance).
{{ config(severity='warn') }}
select fill_key, gross_cost, patient_pay_amount, plan_paid_amount
from {{ ref('fct_pharmacy_claim') }}
where abs(gross_cost - (patient_pay_amount + plan_paid_amount)) > 0.01