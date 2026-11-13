/* =====================================================================
   01_load_raw.sql  -  Step 1a: load the SmartH2O CSVs into PostgreSQL
   Run from psql (SQL Shell), connected to the smart_meter database:
       \i C:/smart-meter-reporting/sql/01_load_raw.sql
   ===================================================================== */
\set ON_ERROR_STOP on
\timing on

-- Folder that holds tegna\ and valencia\ (forward slashes, edit if different)
\cd C:/smart-meter-reporting/data/raw

DROP TABLE IF EXISTS stg_readings, stg_households, raw_readings, raw_households CASCADE;

/* ---------------------------------------------------------------------
   1. Staging tables: every column is TEXT.
   The two sites format numbers differently (Tegna "1332.4", Valencia
   "493,000") and mark blanks differently ("NULL" vs "\N"). Loading as
   text means nothing is rejected or silently mis-read on the way in;
   we convert types in one visible step afterwards.
   The site column is filled through a column DEFAULT that we switch
   between the two loads, which is much faster than an UPDATE afterwards.
   --------------------------------------------------------------------- */
CREATE TABLE stg_readings (
    site            text,
    row_index       text,
    smart_meter_id  text,
    tst             text,
    meter_reading   text
);

CREATE TABLE stg_households (
    site text, row_index text, smart_meter_id text, household_size text,
    household_garden_area text, household_pool_volume text, household_pool text,
    household_garden text, residency_type text, number_bathrooms text,
    environmental_attitude text, irrigation_system text, house_plants text,
    balcony_plants text, building_size text, complex_device text, efficiency text,
    ecomode text, timer text, simple_device text, simple_device_count text
);

-- Tegna (Switzerland)
ALTER TABLE stg_readings   ALTER COLUMN site SET DEFAULT 'TEG';
ALTER TABLE stg_households ALTER COLUMN site SET DEFAULT 'TEG';
\copy stg_readings (row_index, smart_meter_id, tst, meter_reading) FROM 'tegna/smarth2o_anonymized_consumptions.csv' WITH (FORMAT csv, HEADER true)
\copy stg_households (row_index, smart_meter_id, household_size, household_garden_area, household_pool_volume, household_pool, household_garden, residency_type, number_bathrooms, environmental_attitude, irrigation_system, house_plants, balcony_plants, building_size, complex_device, efficiency, ecomode, timer, simple_device, simple_device_count) FROM 'tegna/smarth2o_anonymized_households.csv' WITH (FORMAT csv, HEADER true)

-- Valencia (Spain)
ALTER TABLE stg_readings   ALTER COLUMN site SET DEFAULT 'VAL';
ALTER TABLE stg_households ALTER COLUMN site SET DEFAULT 'VAL';
\copy stg_readings (row_index, smart_meter_id, tst, meter_reading) FROM 'valencia/smarth2o_anonymized_consumptions.csv' WITH (FORMAT csv, HEADER true)
\copy stg_households (row_index, smart_meter_id, household_size, household_garden_area, household_pool_volume, household_pool, household_garden, residency_type, number_bathrooms, environmental_attitude, irrigation_system, house_plants, balcony_plants, building_size, complex_device, efficiency, ecomode, timer, simple_device, simple_device_count) FROM 'valencia/smarth2o_anonymized_households.csv' WITH (FORMAT csv, HEADER true)

/* ---------------------------------------------------------------------
   2. raw_readings: typed copy of the meter reads, nothing removed.
   - meter_key: the same meter number exists in both sites, so the
     business key is site + id (e.g. TEG-34, VAL-34).
   - reading_m3: Valencia's decimal comma becomes a decimal point.
     The README gives no unit; values only make sense as cubic metres
     (we sanity-check this in 02_profile.sql).
   --------------------------------------------------------------------- */
CREATE TABLE raw_readings AS
SELECT
    site,
    site || '-' || smart_meter_id                    AS meter_key,
    smart_meter_id::int                              AS smart_meter_id,
    row_index::bigint                                AS source_row,
    tst::timestamp                                   AS read_ts,
    replace(meter_reading, ',', '.')::numeric(14,3)  AS reading_m3
FROM stg_readings;

CREATE INDEX ix_raw_readings_meter_ts ON raw_readings (meter_key, read_ts);

/* ---------------------------------------------------------------------
   3. raw_households: kept exactly as supplied (text), plus site and
   meter_key. The file has one row per meter x appliance combination,
   so a meter appears many times; we flatten it to one row per property
   when we build dim_property in Step 4.
   --------------------------------------------------------------------- */
CREATE TABLE raw_households AS
SELECT
    site,
    site || '-' || smart_meter_id AS meter_key,
    smart_meter_id, row_index, household_size, household_garden_area,
    household_pool_volume, household_pool, household_garden, residency_type,
    number_bathrooms, environmental_attitude, irrigation_system, house_plants,
    balcony_plants, building_size, complex_device, efficiency, ecomode, timer,
    simple_device, simple_device_count
FROM stg_households;

ANALYZE raw_readings;
ANALYZE raw_households;

-- Load check: compare these with the CSV line counts minus the header
SELECT 'raw_readings' AS table_name, site, COUNT(*) AS row_count FROM raw_readings GROUP BY site
UNION ALL
SELECT 'raw_households', site, COUNT(*) FROM raw_households GROUP BY site
ORDER BY 1, 2;

-- Staging tables have done their job
DROP TABLE stg_readings, stg_households;
