-- =====================================================================
-- Q1. Net takings in USD by venue and month (2025)
--
-- Rules from the brief, and how each is applied:
--   * Net takings = collected - refunded, tax included
--       -> sum of the SIGNED amount in fct_payment (refunds are negative)
--   * Put each booking in the month its ACTIVITY happens, venue local time
--       -> month comes from fct_booking.session_date_local, NOT from
--          the payment date (a deposit paid in Nov for a Jan session
--          counts in Jan)
--   * Convert with the rate for the activity date
--       -> join dim_fx_rate on session_date_local (weekends/holidays use
--          the last published rate)
-- Cancelled bookings are INCLUDED: if a venue kept a non-refundable
-- deposit or a cancellation fee, that money is real takings. A fully
-- refunded cancellation nets to 0 on its own.
-- Test/demo venues are excluded.
-- A venue x month grid is used so a month with no takings shows 0.
-- =====================================================================
with months as (
    select strftime(m, '%Y-%m') as activity_month
    from range(timestamp '2025-01-01', timestamp '2026-01-01', interval 1 month) t(m)
),
venues as (
    select venue_key, platform, venue_name, currency_code
    from gold.dim_venue
    where not is_test
),
takings as (
    select
        b.venue_key,
        strftime(b.session_date_local, '%Y-%m')                              as activity_month,
        sum(p.amount * fx.usd_per_unit) filter (where p.amount > 0)          as collected_usd,
        -sum(p.amount * fx.usd_per_unit) filter (where p.amount < 0)         as refunded_usd,
        sum(p.amount * fx.usd_per_unit)                                      as net_usd
    from gold.fct_payment p
    join gold.fct_booking b  using (booking_key)
    join gold.dim_fx_rate fx on fx.rate_date     = b.session_date_local
                            and fx.currency_code = p.currency_code
    where year(b.session_date_local) = 2025
    group by all
)
select
    v.platform,
    v.venue_name,
    v.currency_code                                  as local_currency,
    m.activity_month,
    round(coalesce(t.collected_usd, 0), 2)           as collected_usd,
    round(coalesce(t.refunded_usd, 0), 2)            as refunded_usd,
    round(coalesce(t.net_usd, 0), 2)                 as net_takings_usd
from venues v
cross join months m
left join takings t on t.venue_key = v.venue_key and t.activity_month = m.activity_month
order by v.platform, v.venue_name, m.activity_month
