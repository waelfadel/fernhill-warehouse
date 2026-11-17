-- =====================================================================
-- Q4. Shared customers in 2025
--
-- Same person = same cleaned email (see gold.dim_customer.person_key):
--   * lower-case and trimmed, so "Amy@X.com " = "amy@x.com"
--   * placeholder emails (noemail@apexvenue.invalid, none@none.com) and
--     blanks are NOT used - otherwise hundreds of strangers would be
--     merged into one "person"
--   * names are not used to merge: same name + different email is
--     treated as two people. (Checked: no cleaned email is shared by
--     two different names, so email alone is a safe key.)
-- Customers without a usable email can't be matched, so the counts are
-- a LOWER BOUND.
--
-- "Booked in 2025" = had a booking whose activity date (local) is in
-- 2025, at a non-test venue. Shown two ways: counting every booking,
-- and counting only bookings that were not cancelled.
-- =====================================================================
with bookings_2025 as (
    select c.person_key, b.venue_key, b.platform, b.is_cancelled
    from gold.fct_booking b
    join gold.dim_customer c using (customer_key)
    join gold.dim_venue v    on v.venue_key = b.venue_key
    where not v.is_test
      and year(b.session_date_local) = 2025
),
per_person as (
    select
        person_key,
        count(distinct venue_key)                                   as venues_all,
        count(distinct platform)                                    as platforms_all,
        count(distinct venue_key) filter (where not is_cancelled)   as venues_kept,
        count(distinct platform)  filter (where not is_cancelled)   as platforms_kept
    from bookings_2025
    group by 1
)
select 'People who booked in 2025' as measure,
       count(*)                                  as counting_all_bookings,
       count(*) filter (where venues_kept > 0)   as counting_non_cancelled_only
from per_person
union all
select 'Booked at more than one venue',
       count(*) filter (where venues_all > 1),
       count(*) filter (where venues_kept > 1)
from per_person
union all
select 'Booked on both Hopscotch and Apex',
       count(*) filter (where platforms_all = 2),
       count(*) filter (where platforms_kept = 2)
from per_person
