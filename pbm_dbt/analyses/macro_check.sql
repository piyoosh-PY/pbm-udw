select
    {{ is_valid_npi("'1669096707'") }}     as should_be_true,
    {{ is_valid_npi("'1669096708'") }}     as should_be_false,
    {{ normalize_ndc("'1234-5678-90'") }}  as expect_01234567890,
    {{ normalize_ndc("'12345-678-90'") }}  as expect_12345067890,
    {{ normalize_ndc("'12345-6789-0'") }}  as expect_12345678900,
    {{ clean_amount("'$1,204.50'") }}      as expect_1204_50,
    {{ parse_date_multi("'09/30/2026'") }} as expect_2026_09_30