-- =====================================================================
-- Q3. Busiest hour of the day per venue (venue local time)
--
--   * Non-cancelled bookings whose activity starts in 2025 (local).
--   * Hour = hour of session_start_local (e.g. 18 = 18:00-18:59).
--   * Counted in BOOKINGS (not guests), as the question asks.
--   * rank() instead of row_number() so that if two hours tie, both are
--     shown rather than one being picked arbitrarily.
-- =====================================================================
with hourly as (
    select
        v.platform,
        v.venue_name,
        b.session_hour_local,
        count(*) as bookings
    from gold.fct_booking b
    join gold.dim_venue v using (venue_key)
    where not v.is_test
      and not b.is_cancelled
      and year(b.session_date_local) = 2025
    group by all
),
ranked as (
    select *,
           rank() over (partition by venue_name order by bookings desc) as rnk,
           sum(bookings) over (partition by venue_name)                 as venue_total
    from hourly
)
select
    platform,
    venue_name,
    lpad(session_hour_local::varchar, 2, '0') || ':00'  as busiest_hour_local,
    bookings,
    round(100.0 * bookings / venue_total, 1)            as share_of_venue_bookings_pct
from ranked
where rnk = 1
order by platform, venue_name
