-- =====================================================================
-- DATA QUALITY CHECKS
--
-- Each check is a VIEW that returns the rows that BREAK an assumption.
--   schema dq      -> must return 0 rows, otherwise run.py FAILS the build
--   schema dq_warn -> known issues we handle; printed for visibility only
-- Adding a check = adding a view. run.py finds them automatically.
-- =====================================================================

create schema if not exists dq;
create schema if not exists dq_warn;

-- ---------- Keys --------------------------------------------------------

create or replace view dq.booking_key_not_unique as
select booking_key, count(*) n from gold.fct_booking group by 1 having count(*) > 1;

create or replace view dq.payment_key_not_unique as
select payment_key, count(*) n from gold.fct_payment group by 1 having count(*) > 1;

create or replace view dq.customer_key_not_unique as
select customer_key, count(*) n from gold.dim_customer group by 1 having count(*) > 1;

create or replace view dq.booking_history_version_not_unique as
select booking_key, version_no, count(*) n
from gold.fct_booking_history group by 1, 2 having count(*) > 1;

-- Duplicates are only safe to drop when they are EXACT copies.
-- If two rows share a key but differ in content, we don't know which
-- one is right -> fail loudly instead of guessing.
create or replace view dq.conflicting_duplicates_in_source as
select 'hop_reservation_versions' as source_table, reservation_key || '/' || version_seq as natural_key
from (select distinct * exclude (_loaded_at) from bronze.hop_reservation_versions)
group by reservation_key, version_seq having count(*) > 1
union all
select 'apx_settlements', site_no || '/' || settle_no
from (select distinct * exclude (_loaded_at) from bronze.apx_settlements)
group by site_no, settle_no having count(*) > 1
union all
select 'apx_tickets', site_no || '/' || ticket_no
from (select distinct * exclude (_loaded_at) from bronze.apx_tickets)
group by site_no, ticket_no having count(*) > 1
union all
select 'hop_money_movements', movement_key
from (select distinct * exclude (_loaded_at) from bronze.hop_money_movements)
group by movement_key having count(*) > 1;

-- ---------- Relationships ----------------------------------------------

create or replace view dq.booking_without_customer as
select b.booking_key, b.customer_key
from gold.fct_booking b
left join gold.dim_customer c using (customer_key)
where c.customer_key is null;

-- A customer record belongs to one venue; its bookings must be at that venue.
create or replace view dq.booking_customer_at_other_venue as
select b.booking_key, b.venue_key, c.venue_key as customer_venue_key
from gold.fct_booking b
join gold.dim_customer c using (customer_key)
where b.venue_key <> c.venue_key;

-- ---------- Money & currency -------------------------------------------

create or replace view dq.payment_currency_differs_from_venue as
select p.payment_key, p.currency_code, v.currency_code as venue_currency
from gold.fct_payment p
join gold.dim_venue v using (venue_key)
where p.currency_code <> v.currency_code;

create or replace view dq.booking_currency_differs_from_venue as
select b.booking_key, b.currency_code, v.currency_code as venue_currency
from gold.fct_booking b
join gold.dim_venue v using (venue_key)
where b.currency_code <> v.currency_code;

-- Hopscotch sends amounts as positive numbers; the direction gives the sign.
create or replace view dq.hop_movement_value_not_positive as
select movement_key, value
from bronze.hop_money_movements
where try_cast(value as decimal(12,2)) is null or value::decimal(12,2) <= 0;

-- Every currency unit received in silver must end up either in
-- gold.fct_payment or in the audit table: nothing can disappear.
create or replace view dq.money_does_not_reconcile as
with src as (
    select 'Hopscotch' platform, currency_code, sum(amount) amt from silver.hop_money_movements group by all
    union all
    select 'Apex', s.currency_code, sum(st.amount)
    from silver.apx_settlements st join silver.apx_sites s using (site_no) group by all
),
tgt as (
    select platform, currency_code, sum(amount) amt from (
        select platform, currency_code, amount from gold.fct_payment
        union all
        select platform, currency_code, amount from gold.audit_unmatched_payments
    ) group by all
)
select s.platform, s.currency_code, s.amt as silver_total, t.amt as gold_total
from src s
full join tgt t using (platform, currency_code)
where s.amt is distinct from t.amt;

-- Some unmatched payments are expected, but a lot would mean the
-- booking extract is incomplete. Fail if more than 1% are unmatched.
create or replace view dq.too_many_unmatched_payments as
select count(*) as unmatched,
       (select count(*) from gold.fct_payment) as matched
from gold.audit_unmatched_payments
having count(*) > 0.01 * (select count(*) from gold.fct_payment);

-- ---------- FX ----------------------------------------------------------

-- Every activity date must have a USD rate, or Q1 would silently drop money.
create or replace view dq.fx_rate_missing_for_booking as
select b.booking_key, b.session_date_local, b.currency_code
from gold.fct_booking b
left join gold.dim_fx_rate fx
       on fx.rate_date = b.session_date_local and fx.currency_code = b.currency_code
where fx.usd_per_unit is null;

-- Weekend fill-forward should never reach back more than a few days.
create or replace view dq.fx_rate_too_stale as
select rate_date, currency_code, source_rate_date
from gold.dim_fx_rate
where date_diff('day', source_rate_date, rate_date) > 5;

-- ---------- Booking logic ----------------------------------------------

-- Hopscotch versions should be 1, 2, 3 ... with no gaps.
create or replace view dq.hop_version_gaps as
select reservation_key, count(*) n_versions, max(version_seq) max_version
from silver.hop_reservation_versions
group by 1
having count(*) <> max(version_seq) or min(version_seq) <> 1;

-- Assumption: a cancellation is final (no LIVE version after a CANCELLED one).
create or replace view dq.hop_reinstated_after_cancel as
select a.reservation_key
from silver.hop_reservation_versions a
join silver.hop_reservation_versions b
  on a.reservation_key = b.reservation_key and b.version_seq > a.version_seq
where a.status = 'CANCELLED' and b.status = 'LIVE';

-- Apex: WITHDRAWN tickets must have a withdrawn time, and only those.
create or replace view dq.apx_withdrawn_inconsistent as
select site_no, ticket_no, outcome, withdrawn_at_local
from silver.apx_tickets
where (outcome = 'WITHDRAWN') <> (withdrawn_at_local is not null);

-- A booking can't be made after the day of the activity.
create or replace view dq.booked_after_activity_date as
select booking_key, booked_at_local, session_start_local
from gold.fct_booking
where lead_time_days < 0;

-- New codes in the source would silently fall through CASE statements.
create or replace view dq.unexpected_code_values as
select 'hop.direction' as field, direction as value from silver.hop_money_movements where direction not in ('IN', 'OUT')
union all select 'hop.status', status from silver.hop_reservation_versions where status not in ('LIVE', 'CANCELLED')
union all select 'apx.outcome', outcome from silver.apx_tickets where outcome not in ('FULFILLED', 'WITHDRAWN')
union all select 'payment_method', payment_method from gold.fct_payment where payment_method not in ('card', 'cash', 'voucher')
union all select 'currency', currency_code from gold.dim_venue where currency_code not in ('USD', 'GBP', 'EUR', 'AUD');

-- Nothing may be lost between bronze and silver except exact duplicates.
create or replace view dq.rows_lost_bronze_to_silver as
with c as (
    select 'hop_reservation_versions' t,
           (select count(*) from (select distinct * exclude (_loaded_at) from bronze.hop_reservation_versions)) b,
           (select count(*) from silver.hop_reservation_versions) s
    union all select 'hop_money_movements',
           (select count(*) from (select distinct * exclude (_loaded_at) from bronze.hop_money_movements)),
           (select count(*) from silver.hop_money_movements)
    union all select 'apx_tickets',
           (select count(*) from (select distinct * exclude (_loaded_at) from bronze.apx_tickets)),
           (select count(*) from silver.apx_tickets)
    union all select 'apx_settlements',
           (select count(*) from (select distinct * exclude (_loaded_at) from bronze.apx_settlements)),
           (select count(*) from silver.apx_settlements)
)
select * from c where b <> s;

-- =========================== WARNINGS ===================================

create or replace view dq_warn.exact_duplicates_removed as
select 'hop_reservation_versions' as source_table,
       (select count(*) from bronze.hop_reservation_versions) - (select count(*) from silver.hop_reservation_versions) as rows_removed
union all
select 'apx_settlements',
       (select count(*) from bronze.apx_settlements) - (select count(*) from silver.apx_settlements);

create or replace view dq_warn.unmatched_payments as
select * from gold.audit_unmatched_payments;

create or replace view dq_warn.customers_without_usable_email as
select platform, count(*) as customers
from gold.dim_customer
where not is_matchable
group by 1;
