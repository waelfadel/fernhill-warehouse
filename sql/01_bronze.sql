-- =====================================================================
-- BRONZE: raw copies of the source files, exactly as delivered.
--
-- * Every column is loaded as text (all_varchar = true). Nothing is
--   cast, cleaned or removed here, so bronze always matches the source
--   and we can re-derive silver if a cleaning rule turns out to be wrong.
-- * Two audit columns are added to every table:
--     _source_file : which file the row came from
--     _loaded_at   : when this load ran
-- * Table names are prefixed with the platform (hop_ / apx_) so tables
--   with the same idea from different sources never collide.
-- =====================================================================

create schema if not exists bronze;

create or replace table bronze.hop_operators as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/hopscotch/operators.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.hop_patrons as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/hopscotch/patrons.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.hop_reservation_versions as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/hopscotch/reservation_versions.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.hop_money_movements as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/hopscotch/money_movements.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.apx_sites as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/apex/sites.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.apx_profiles as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/apex/profiles.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.apx_tickets as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/apex/tickets.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.apx_settlements as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/apex/settlements.csv', header = true, all_varchar = true, filename = true);

create or replace table bronze.fx_rates_daily as
select * exclude (filename), filename as _source_file, current_timestamp as _loaded_at
from read_csv('data/rates_daily.csv', header = true, all_varchar = true, filename = true);
