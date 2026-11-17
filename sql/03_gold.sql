-- =====================================================================
-- GOLD: one unified, platform-neutral model for analysts.
--
-- An analyst never needs to know which system a row came from:
--   * Hopscotch reservations and Apex tickets are both "bookings"
--   * Hopscotch money movements and Apex settlements are both "payments"
--   * operators and sites are both "venues"
--   * patrons and profiles are both "customers"
-- Every row still carries `platform` for traceability.
--
-- Keys: <PLATFORM PREFIX>-<source natural key>. Apex keys include the
-- site number because each Apex site has its own database, so ticket 1
-- exists at several sites.
--     venue     HOP-1          APX-3
--     customer  HOP-310001     APX-3-125
--     booking   HOP-8800001    APX-3-57
--     payment   HOP-4000001    APX-3-812
--
-- Time: every event is stored twice - in UTC (to compare across venues)
-- and in the venue's local time (for "which month / which hour"
-- questions). Hopscotch arrives in UTC, Apex in local time.
-- Money: always major units, signed (+ received, - refunded), in the
-- venue's own currency. USD conversion is done with gold.dim_fx_rate.
-- =====================================================================

create schema if not exists gold;

-- ---------------------------------------------------------------------
-- dim_venue  | grain: one row per venue (Hopscotch operator / Apex site)
-- ---------------------------------------------------------------------
create or replace table gold.dim_venue as
select
    'HOP-' || operator_key          as venue_key,
    'Hopscotch'                     as platform,
    operator_key::varchar           as source_venue_id,
    venue_name,
    vertical,
    country_code,
    currency_code,
    time_zone,
    is_test
from silver.hop_operators
union all
select
    'APX-' || site_no,
    'Apex',
    site_no::varchar,
    venue_name,
    'Go-karting',
    country_code,
    currency_code,
    time_zone,
    is_test
from silver.apx_sites;

-- ---------------------------------------------------------------------
-- dim_customer | grain: one row per customer record at one venue
--
-- person_key links records that belong to the same person. Rule:
--   same cleaned email (lower-case, trimmed, placeholders removed)
--   => same person, on any venue and either platform.
-- A record with no usable email gets its own person_key (it can't be
-- matched, so it is counted as a separate person - a conservative
-- choice that can only UNDER-count shared customers).
-- We do NOT match on name alone: two different emails with the same
-- name (e.g. two "Amelia Lewis") are treated as different people.
-- ---------------------------------------------------------------------
create or replace table gold.dim_customer as
with unioned as (
    select
        'HOP-' || p.patron_key                  as customer_key,
        'Hopscotch'                             as platform,
        'HOP-' || p.operator_key                as venue_key,
        p.patron_key::varchar                   as source_customer_id,
        p.first_name,
        p.last_name,
        p.email_clean                           as email,
        p.registered_at_utc
    from silver.hop_patrons p
    union all
    select
        'APX-' || p.site_no || '-' || p.profile_no,
        'Apex',
        'APX-' || p.site_no,
        p.site_no || '-' || p.profile_no,
        p.first_name,
        p.last_name,
        p.email_clean,
        timezone(s.time_zone, p.joined_at_local)          -- local -> UTC
    from silver.apx_profiles p
    join silver.apx_sites s using (site_no)
)
select
    customer_key,
    platform,
    venue_key,
    source_customer_id,
    first_name,
    last_name,
    email,
    case when email is not null
         then 'PER-' || left(md5(email), 12)
         else 'PER-' || customer_key end                  as person_key,
    email is not null                                     as is_matchable,
    registered_at_utc
from unioned;

-- ---------------------------------------------------------------------
-- fct_booking_history | grain: one row per version of a booking (SCD2)
--
-- Hopscotch already writes a full new version on every change, so each
-- version becomes one row. valid_to = when the next version started.
-- Apex keeps only the latest state; we rebuild what we can:
--   version 1 = ticket opened (CONFIRMED)
--   version 2 = ticket withdrawn (CANCELLED), if it was.
-- In production Apex history would come from snapshotting each load.
-- ---------------------------------------------------------------------
create or replace table gold.fct_booking_history as
with hop as (
    select
        'HOP-' || reservation_key                         as booking_key,
        version_seq                                       as version_no,
        valid_from_utc,
        case status when 'CANCELLED' then 'CANCELLED' else 'CONFIRMED' end as status,
        session_start_utc,
        party_size,
        price_gross,
        currency_code
    from silver.hop_reservation_versions
),
apx_base as (
    select t.*, s.time_zone, s.currency_code
    from silver.apx_tickets t
    join silver.apx_sites s using (site_no)
),
apx as (
    select
        'APX-' || site_no || '-' || ticket_no             as booking_key,
        1                                                 as version_no,
        timezone(time_zone, opened_at_local)              as valid_from_utc,
        'CONFIRMED'                                       as status,
        timezone(time_zone, session_start_local)          as session_start_utc,
        party_size, price_gross, currency_code
    from apx_base
    union all
    select
        'APX-' || site_no || '-' || ticket_no,
        2,
        timezone(time_zone, withdrawn_at_local),
        'CANCELLED',
        timezone(time_zone, session_start_local),
        party_size, price_gross, currency_code
    from apx_base
    where outcome = 'WITHDRAWN'
),
all_versions as (
    select * from hop
    union all
    select * from apx
)
select
    booking_key,
    version_no,
    status,
    session_start_utc,
    party_size,
    price_gross,
    currency_code,
    valid_from_utc,
    lead(valid_from_utc) over w                           as valid_to_utc,
    lead(valid_from_utc) over w is null                   as is_current
from all_versions
window w as (partition by booking_key order by version_no);

-- ---------------------------------------------------------------------
-- fct_booking | grain: one row per booking, in its CURRENT state
-- This is the main table analysts use.
-- ---------------------------------------------------------------------
create or replace table gold.fct_booking as
with hop_current as (
    select
        'HOP-' || r.reservation_key                       as booking_key,
        'Hopscotch'                                       as platform,
        'HOP-' || r.operator_key                          as venue_key,
        'HOP-' || r.patron_key                            as customer_key,
        r.product_name,
        r.booked_at_utc,
        r.session_start_utc,
        r.status = 'CANCELLED'                            as is_cancelled,
        r.party_size,
        r.price_gross,
        r.currency_code
    from silver.hop_reservation_versions r
    qualify row_number() over (partition by r.reservation_key order by r.version_seq desc) = 1
),
hop_cancel as (
    -- when the booking was cancelled = first version that says CANCELLED
    select 'HOP-' || reservation_key as booking_key, min(valid_from_utc) as cancelled_at_utc
    from silver.hop_reservation_versions
    where status = 'CANCELLED'
    group by 1
),
hop as (
    select h.*, c.cancelled_at_utc
    from hop_current h
    left join hop_cancel c using (booking_key)
),
apx as (
    select
        'APX-' || t.site_no || '-' || t.ticket_no         as booking_key,
        'Apex'                                            as platform,
        'APX-' || t.site_no                               as venue_key,
        'APX-' || t.site_no || '-' || t.profile_no        as customer_key,
        t.product_name,
        timezone(s.time_zone, t.opened_at_local)          as booked_at_utc,
        timezone(s.time_zone, t.session_start_local)      as session_start_utc,
        t.outcome = 'WITHDRAWN'                           as is_cancelled,
        t.party_size,
        t.price_gross,
        s.currency_code,
        timezone(s.time_zone, t.withdrawn_at_local)       as cancelled_at_utc
    from silver.apx_tickets t
    join silver.apx_sites s using (site_no)
),
unioned as (
    select * from hop
    union all by name
    select * from apx
),
localised as (
    select
        u.*,
        timezone(v.time_zone, u.booked_at_utc)            as booked_at_local,      -- UTC -> local
        timezone(v.time_zone, u.session_start_utc)        as session_start_local
    from unioned u
    join gold.dim_venue v using (venue_key)
)
select
    booking_key,
    platform,
    venue_key,
    customer_key,
    product_name,
    booked_at_utc,
    booked_at_local,
    session_start_utc,
    session_start_local,
    session_start_local::date                             as session_date_local,
    hour(session_start_local)                             as session_hour_local,
    date_diff('day', booked_at_local::date, session_start_local::date) as lead_time_days,
    case
        when date_diff('day', booked_at_local::date, session_start_local::date) = 0  then '1. Same day'
        when date_diff('day', booked_at_local::date, session_start_local::date) <= 7  then '2. 1-7 days'
        when date_diff('day', booked_at_local::date, session_start_local::date) <= 30 then '3. 8-30 days'
        else '4. 31+ days'
    end                                                   as lead_time_bucket,
    is_cancelled,
    cancelled_at_utc,
    party_size,
    price_gross,
    currency_code
from localised;

-- ---------------------------------------------------------------------
-- fct_payment | grain: one row per money movement (in or out)
-- amount is signed: + money received, - money refunded. Tax included.
-- Only payments that belong to a known booking are loaded here; the
-- rest go to gold.audit_unmatched_payments so nothing is silently lost.
-- ---------------------------------------------------------------------
create or replace table gold.fct_payment as
with all_payments as (
    select
        'HOP-' || m.movement_key                          as payment_key,
        'Hopscotch'                                       as platform,
        'HOP-' || m.reservation_key                       as booking_key,
        m.moved_at_utc                                    as paid_at_utc,
        m.amount,
        m.currency_code,
        m.payment_method,
        m.memo
    from silver.hop_money_movements m
    union all
    select
        'APX-' || st.site_no || '-' || st.settle_no,
        'Apex',
        'APX-' || st.site_no || '-' || st.ticket_no,
        timezone(s.time_zone, st.settled_at_local),
        st.amount,
        s.currency_code,
        st.payment_method,
        null
    from silver.apx_settlements st
    join silver.apx_sites s using (site_no)
)
select
    p.payment_key,
    p.platform,
    p.booking_key,
    b.venue_key,
    p.paid_at_utc,
    timezone(v.time_zone, p.paid_at_utc)                  as paid_at_local,
    p.amount,
    p.currency_code,
    p.amount < 0                                          as is_refund,
    p.payment_method,
    p.memo
from all_payments p
join gold.fct_booking b using (booking_key)
join gold.dim_venue v on v.venue_key = b.venue_key;

-- Payments whose booking does not exist in the booking data.
-- They can't be given a venue or an activity month, so they are kept
-- here for investigation instead of being dropped silently.
create or replace table gold.audit_unmatched_payments as
select 'HOP-' || movement_key as payment_key, 'Hopscotch' as platform,
       'HOP-' || reservation_key as booking_key, amount, currency_code,
       moved_at_utc::varchar as paid_at, payment_method
from silver.hop_money_movements
where 'HOP-' || reservation_key not in (select booking_key from gold.fct_booking)
union all
select 'APX-' || st.site_no || '-' || st.settle_no, 'Apex',
       'APX-' || st.site_no || '-' || st.ticket_no, st.amount, s.currency_code,
       st.settled_at_local::varchar || ' (local)', st.payment_method
from silver.apx_settlements st
join silver.apx_sites s using (site_no)
where 'APX-' || st.site_no || '-' || st.ticket_no not in (select booking_key from gold.fct_booking);

-- ---------------------------------------------------------------------
-- dim_fx_rate | grain: one row per calendar day per currency
--
-- Rates are only published on business days. For weekends and holidays
-- we use the most recent earlier published rate (ASOF join).
-- USD is added with a rate of 1 so every currency converts the same way.
-- ---------------------------------------------------------------------
create or replace table gold.dim_fx_rate as
with bounds as (
    select
        least((select min(rate_date) from silver.fx_rates_daily),
              (select min(session_date_local) from gold.fct_booking))  as d_from,
        greatest((select max(rate_date) from silver.fx_rates_daily),
                 (select max(session_date_local) from gold.fct_booking)) as d_to
),
calendar as (
    select range::date as rate_date
    from bounds, range(d_from::timestamp, (d_to + 1)::timestamp, interval 1 day)
),
currencies as (
    select distinct currency_code from silver.fx_rates_daily
),
grid as (
    select c.rate_date, cu.currency_code
    from calendar c cross join currencies cu
),
filled as (
    select
        g.rate_date,
        g.currency_code,
        r.usd_per_unit,
        r.rate_date                                       as source_rate_date
    from grid g
    asof left join silver.fx_rates_daily r
        on g.currency_code = r.currency_code
       and g.rate_date >= r.rate_date
)
select rate_date, currency_code, usd_per_unit, source_rate_date,
       rate_date <> source_rate_date                      as is_filled
from filled
union all
select rate_date, 'USD', 1.000000, rate_date, false
from calendar;
