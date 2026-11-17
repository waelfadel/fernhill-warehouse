-- =====================================================================
-- SILVER: cleaned, typed, de-duplicated copies of each source table.
--
-- Still one table per source table (source shape), but:
--   * text is cast to proper types (int, decimal, timestamp, boolean)
--   * exact duplicate rows are removed (one row per natural key)
--   * units are made consistent (Apex cents -> major units,
--     Hopscotch IN/OUT -> signed amounts)
--   * emails are normalised and placeholder emails become NULL
--   * columns get clear, consistent names
-- Combining the two platforms happens in GOLD, not here.
-- =====================================================================

create schema if not exists silver;

-- ---------------------------------------------------------------------
-- Reference list of known placeholder emails (found while profiling).
-- Staff type these when a customer has no email. They must never be
-- used to match people, so they are turned into NULL.
-- ---------------------------------------------------------------------
create or replace table silver.ref_placeholder_emails as
select * from (values
    ('noemail@apexvenue.invalid', 'Apex kiosk/staff placeholder'),
    ('none@none.com',             'Hopscotch placeholder')
) t(email, note);

-- Reusable cleaning rule: lower-case + trim, then NULL if blank,
-- a known placeholder, or not shaped like an email.
create or replace macro silver.clean_email(e) as (
    case
        when e is null then null
        when trim(e) = '' then null
        when lower(trim(e)) in (select email from silver.ref_placeholder_emails) then null
        when not regexp_full_match(lower(trim(e)), '[^@\s]+@[^@\s]+\.[^@\s]+') then null
        else lower(trim(e))
    end
);

-- =========================== HOPSCOTCH ===============================

create or replace table silver.hop_operators as
select
    operator_key::int                  as operator_key,
    trim(trading_name)                 as venue_name,
    vertical,
    iso_country                        as country_code,
    iso_currency                       as currency_code,
    tz_name                            as time_zone,
    lower(is_sandbox) = 'true'         as is_test
from bronze.hop_operators
qualify row_number() over (partition by operator_key order by _loaded_at) = 1;

create or replace table silver.hop_patrons as
select
    patron_key::int                    as patron_key,
    operator_key::int                  as operator_key,
    contact_email                      as email_raw,
    silver.clean_email(contact_email)  as email_clean,
    trim(given_name)                   as first_name,
    trim(family_name)                  as last_name,
    registered_ts::timestamptz         as registered_at_utc
from bronze.hop_patrons
qualify row_number() over (partition by patron_key order by _loaded_at) = 1;

-- 40 rows in the source are exact duplicates of another row
-- (same reservation_key + version_seq + identical content). Keep one.
create or replace table silver.hop_reservation_versions as
select
    reservation_key::bigint            as reservation_key,
    version_seq::int                   as version_seq,
    operator_key::int                  as operator_key,
    patron_key::int                    as patron_key,
    offering                           as product_name,
    session_start_ts::timestamptz      as session_start_utc,
    booked_ts::timestamptz             as booked_at_utc,
    valid_from_ts::timestamptz         as valid_from_utc,
    lifecycle                          as status,          -- LIVE / CANCELLED
    party_size::int                    as party_size,
    price_net::decimal(12,2)           as price_net,
    price_tax::decimal(12,2)           as price_tax,
    price_net::decimal(12,2) + price_tax::decimal(12,2) as price_gross,
    iso_currency                       as currency_code
from bronze.hop_reservation_versions
qualify row_number() over (partition by reservation_key, version_seq order by _loaded_at) = 1;

-- Money is always positive in the source; direction gives the sign.
-- Here IN stays positive and OUT (refund) becomes negative.
create or replace table silver.hop_money_movements as
select
    movement_key::bigint               as movement_key,
    reservation_key::bigint            as reservation_key,
    direction,
    case direction when 'IN'  then  value::decimal(12,2)
                   when 'OUT' then -value::decimal(12,2) end as amount,
    iso_currency                       as currency_code,
    moved_ts::timestamptz              as moved_at_utc,
    lower(rail)                        as payment_method,  -- card / cash / voucher
    nullif(trim(memo), '')             as memo
from bronze.hop_money_movements
qualify row_number() over (partition by movement_key order by _loaded_at) = 1;

-- ============================== APEX =================================
-- Apex keys are only unique WITHIN a site (each site has its own
-- database), so every Apex natural key is (site_no, <number>).

create or replace table silver.apx_sites as
select
    site_no::int                       as site_no,
    trim(site_title)                   as venue_name,
    iso_country                        as country_code,
    iso_currency                       as currency_code,
    olson_tz                           as time_zone,
    is_training = '1'                  as is_test
from bronze.apx_sites
qualify row_number() over (partition by site_no order by _loaded_at) = 1;

create or replace table silver.apx_profiles as
select
    site_no::int                       as site_no,
    profile_no::int                    as profile_no,
    mail                               as email_raw,
    silver.clean_email(mail)           as email_clean,
    trim(first)                        as first_name,
    trim(surname)                      as last_name,
    joined_local::timestamp            as joined_at_local
from bronze.apx_profiles
qualify row_number() over (partition by site_no, profile_no order by _loaded_at) = 1;

-- gross_minor is in cents/pence -> divide by 100 to get major units,
-- the same unit as every other amount in the warehouse.
create or replace table silver.apx_tickets as
select
    site_no::int                       as site_no,
    ticket_no::int                     as ticket_no,
    profile_no::int                    as profile_no,
    opened_local::timestamp            as opened_at_local,
    session_local::timestamp           as session_start_local,
    product_label                      as product_name,
    head_count::int                    as party_size,
    (gross_minor::bigint / 100.0)::decimal(12,2) as price_gross,
    outcome,                                                -- FULFILLED / WITHDRAWN
    withdrawn_local::timestamp         as withdrawn_at_local
from bronze.apx_tickets
qualify row_number() over (partition by site_no, ticket_no order by _loaded_at) = 1;

-- 18 rows are exact duplicates of another settlement. Keep one.
-- settle_value is already signed (negative = refund).
create or replace table silver.apx_settlements as
select
    site_no::int                       as site_no,
    settle_no::int                     as settle_no,
    ticket_no::int                     as ticket_no,
    settle_value::decimal(12,2)        as amount,
    settle_local::timestamp            as settled_at_local,
    lower(instrument)                  as payment_method   -- card / cash / voucher
from bronze.apx_settlements
qualify row_number() over (partition by site_no, settle_no order by _loaded_at) = 1;

-- =========================== FX RATES ================================

create or replace table silver.fx_rates_daily as
select
    as_of::date                        as rate_date,
    base_ccy                           as currency_code,
    usd_per_unit::decimal(18,6)        as usd_per_unit
from bronze.fx_rates_daily
where quote_ccy = 'USD'
qualify row_number() over (partition by as_of, base_ccy order by _loaded_at) = 1;
