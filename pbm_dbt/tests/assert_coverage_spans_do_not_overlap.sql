-- A member can't be covered by two plan versions on the same day; point-in-time joins would double count.
select a.member_key, a.version_number, b.version_number as overlapping_version,
       a.effective_from, a.effective_to, b.effective_from as other_from, b.effective_to as other_to
from {{ ref('int_member_coverage_spans') }} a
join {{ ref('int_member_coverage_spans') }} b
  on a.member_key = b.member_key
 and a.version_number < b.version_number
 and a.effective_from <= b.effective_to
 and b.effective_from <= a.effective_to
where a.effective_from <= a.effective_to
  and b.effective_from <= b.effective_to