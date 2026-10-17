{#-
Reusable cleaning macros for Silver Models.
Each macro RETURNS a SQL expression;
dbt pastes it into the model at compile time.
-#}

{% macro normalize_ndc(col) -%}
    {# Convert any NDC rendering to the 11-digit 5-4-2 billing format; NULL if unrecognizable. -#}
    case
        when {{ col }} is null then null
        when regexp_full_match({{ col }}, '\d{11}') then {{ col }}
        when regexp_full_match({{ col }}, '\d{5}-\d{4}-\d{2}') then replace({{ col }}, '-', '')
        when regexp_full_match({{ col }}, '\d{4}-\d{4}-\d{2}') then '0' || replace({{ col }}, '-', '')
        when regexp_full_match({{ col }}, '\d{5}-\d{3}-\d{2}')
            then split_part({{ col }}, '-', 1) || '0' || split_part({{ col }}, '-', 2) || split_part({{ col }}, '-', 3)
        when regexp_full_match({{ col }}, '\d{5}-\d{4}-\d{1}')
            then split_part({{ col }}, '-', 1) || split_part({{ col }}, '-', 2) || '0' || split_part({{ col }}, '-', 3)
        else null
    end 
{%- endmacro %}

{% macro is_valid_npi(col) -%}
    {#- NPI check digit = Luhn over '80840' || npi (15 digits). Double every 2nd digit from the right. -#}
    (
        coalesce(regexp_full_match({{ col }}, '\d{10}'), false)
        and list_sum(
            list_transform(
                range(1, 16),
                lambda i: case
                    when i % 2 = 0 then
                        case when cast(substr('80840' || {{ col }}, 16 - i, 1) as integer) * 2 > 9
                             then cast(substr('80840' || {{ col }}, 16 - i, 1) as integer) * 2 - 9
                             else cast(substr('80840' || {{ col }}, 16 - i, 1) as integer) * 2 end
                    else cast(substr('80840' || {{ col }}, 16 - i, 1) as integer)
                end
            )
        ) % 10 = 0
    )
{%- endmacro %}

{% macro clean_amount(col) -%}
    {#- '$12.50', ' 12.50 ', '1,204.00' -> decimal; NULL if still not a number. -#}
    try_cast(replace(replace(trim({{ col }}), '$', ''), ',', '') as decimal(12, 2))
{%- endmacro %}


{% macro parse_date_multi(col) -%}
    {#- Accept ISO (2026-09-30) or US (09/30/2026); NULL if neither. -#}
    coalesce(
        try_strptime({{ col }}, '%Y-%m-%d'),
        try_strptime({{ col }}, '%m/%d/%Y')
    )::date
{%- endmacro %}