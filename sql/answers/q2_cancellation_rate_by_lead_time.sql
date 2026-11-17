-- =====================================================================
-- Q2. Cancellation rate by platform and booking lead time
--
--   * Population: bookings whose activity date (venue local) is in 2025,
--     test/demo venues excluded.
--   * Lead time = activity date - booking date, both as calendar dates in
--     the VENUE's local time (fct_booking.lead_time_days). Using local
--     dates means "same day" really is the same day for the customer.
--   * Buckets: same day (0), 1-7, 8-30, 31+ days.
--   * Cancelled = the booking's CURRENT state is cancelled
--     (Hopscotch CANCELLED version, Apex WITHDRAWN ticket).
--   * A per-platform "All" row is added with GROUPING SETS.
-- =====================================================================
select
    b.platform,
    coalesce(b.lead_time_bucket, 'All lead times')                    as lead_time_bucket,
    count(*)                                                          as bookings,
    count(*) filter (where b.is_cancelled)                            as cancelled,
    round(100.0 * count(*) filter (where b.is_cancelled) / count(*), 1) as cancellation_rate_pct
from gold.fct_booking b
join gold.dim_venue v using (venue_key)
where not v.is_test
  and year(b.session_date_local) = 2025
group by grouping sets ((b.platform, b.lead_time_bucket), (b.platform))
order by b.platform, b.lead_time_bucket nulls last
