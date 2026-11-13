/* =====================================================================
   02_profile.sql  -  Step 1b: profile the raw data and build `meters`
   Run from psql:  \i C:/smart-meter-reporting/sql/02_profile.sql
   Copy the output of each P-query into docs/profiling_note.md.
   ===================================================================== */
\set ON_ERROR_STOP on
\pset null '(null)'

\echo '== P1. Size and date range per site'
SELECT site,
       COUNT(*)                    AS reads,
       COUNT(DISTINCT meter_key)   AS meters,
       MIN(read_ts)                AS first_read,
       MAX(read_ts)                AS last_read
FROM raw_readings
GROUP BY site ORDER BY site;

\echo '== P2. Duplicate timestamps (same meter, same read_ts)'
WITH d AS (
    SELECT site, meter_key, read_ts,
           COUNT(*)                   AS copies,
           COUNT(DISTINCT reading_m3) AS distinct_values
    FROM raw_readings
    GROUP BY site, meter_key, read_ts
    HAVING COUNT(*) > 1
)
SELECT site,
       COUNT(*)                                         AS duplicated_timestamps,
       SUM(copies - 1)                                  AS extra_rows,
       COUNT(*) FILTER (WHERE distinct_values > 1)      AS dupes_with_conflicting_values,
       COUNT(DISTINCT meter_key)                        AS meters_affected
FROM d GROUP BY site ORDER BY site;

\echo '== P3. Most common gaps between consecutive reads (top 8 per site)'
WITH g AS (
    SELECT site,
           read_ts - LAG(read_ts) OVER (PARTITION BY meter_key ORDER BY read_ts) AS gap
    FROM raw_readings
), c AS (
    SELECT site, gap, COUNT(*) AS n,
           ROW_NUMBER() OVER (PARTITION BY site ORDER BY COUNT(*) DESC) AS rk,
           ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY site), 2) AS pct
    FROM g WHERE gap IS NOT NULL
    GROUP BY site, gap
)
SELECT site, gap, n, pct FROM c WHERE rk <= 8 ORDER BY site, rk;

/* ---------------------------------------------------------------------
   meters: one row per meter with its typical reading interval.
   The median gap decides each meter's cadence. This matters later:
   hourly analysis (demand profile, night use, continuous flow) can
   only use meters that are read hourly.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS meters CASCADE;
CREATE TABLE meters AS
WITH g AS (
    SELECT site, meter_key, smart_meter_id, read_ts,
           EXTRACT(EPOCH FROM read_ts - LAG(read_ts) OVER (PARTITION BY meter_key ORDER BY read_ts)) AS gap_s
    FROM raw_readings
)
SELECT site,
       meter_key,
       MIN(smart_meter_id)                                     AS smart_meter_id,
       COUNT(*)                                                AS reads,
       MIN(read_ts)                                            AS first_read,
       MAX(read_ts)                                            AS last_read,
       ROUND((EXTRACT(EPOCH FROM MAX(read_ts) - MIN(read_ts)) / 86400)::numeric, 1) AS span_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_s)      AS median_gap_s,
       CASE
           WHEN PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_s) BETWEEN 3300 AND 3900   THEN 'Hourly'
           WHEN PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_s) BETWEEN 82800 AND 90000 THEN 'Daily'
           ELSE 'Irregular'
       END                                                     AS cadence
FROM g
GROUP BY site, meter_key;

ALTER TABLE meters ADD PRIMARY KEY (meter_key);
ALTER TABLE meters ADD COLUMN has_household_info boolean;
UPDATE meters m
SET has_household_info = EXISTS (
    SELECT 1 FROM raw_households h
    WHERE h.meter_key = m.meter_key
      AND NULLIF(NULLIF(h.residency_type, 'NULL'), '\N') IS NOT NULL);

\echo '== P4. Meters by reading cadence'
SELECT site, cadence, COUNT(*) AS meters,
       ROUND(AVG(span_days)) AS avg_span_days,
       ROUND(AVG(reads))     AS avg_reads
FROM meters GROUP BY site, cadence ORDER BY site, meters DESC;

\echo '== P5. Reads per meter (spread)'
SELECT site,
       MIN(reads) AS min_reads,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reads) AS median_reads,
       MAX(reads) AS max_reads,
       COUNT(*) FILTER (WHERE span_days < 30) AS meters_under_30_days
FROM meters GROUP BY site ORDER BY site;

\echo '== P6. Household file: coverage and features (one row per meter)'
-- The household file repeats each meter once per appliance combination,
-- and some of those repeats have blank features, so we take MAX per meter.
WITH one AS (
    SELECT site, meter_key,
           COUNT(*)                                                AS rows_in_file,
           MAX(NULLIF(NULLIF(residency_type,   'NULL'), '\N'))     AS residency_type,
           MAX(NULLIF(NULLIF(household_garden, 'NULL'), '\N'))     AS garden,
           MAX(NULLIF(NULLIF(household_pool,   'NULL'), '\N'))     AS pool,
           MAX(NULLIF(NULLIF(irrigation_system,'NULL'), '\N'))     AS irrigation
    FROM raw_households GROUP BY site, meter_key
), j AS (
    SELECT one.*, m.meter_key IS NOT NULL AS has_readings, m.cadence
    FROM one LEFT JOIN meters m USING (meter_key)
)
SELECT site,
       SUM(rows_in_file)                                             AS household_rows,
       COUNT(*)                                                      AS household_meters,
       COUNT(*) FILTER (WHERE has_readings)                          AS with_readings,
       COUNT(*) FILTER (WHERE residency_type IS NOT NULL)            AS with_features,
       COUNT(*) FILTER (WHERE residency_type IS NOT NULL AND has_readings) AS usable,
       COUNT(*) FILTER (WHERE has_readings AND residency_type = 'Flat')    AS usable_flats,
       COUNT(*) FILTER (WHERE has_readings AND residency_type IN ('House','Single Family')) AS usable_houses,
       COUNT(*) FILTER (WHERE has_readings AND garden::numeric = 1)        AS usable_gardens,
       COUNT(*) FILTER (WHERE has_readings AND pool::numeric = 1)          AS usable_pools,
       COUNT(*) FILTER (WHERE has_readings AND irrigation::numeric = 1)    AS usable_irrigation
FROM j GROUP BY site ORDER BY site;

\echo '== P7. Unit sanity check: typical use per property per day'
-- Ignores negative steps and steps over 5 units (we deal with those in Step 3)
WITH d AS (
    SELECT site, meter_key,
           reading_m3 - LAG(reading_m3) OVER (PARTITION BY meter_key ORDER BY read_ts) AS step
    FROM raw_readings
), per_meter AS (
    SELECT d.site, d.meter_key,
           SUM(step) FILTER (WHERE step BETWEEN 0 AND 5) / NULLIF(MAX(m.span_days), 0) AS units_per_day
    FROM d JOIN meters m USING (meter_key)
    GROUP BY d.site, d.meter_key
)
SELECT site,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY units_per_day)::numeric, 3) AS median_units_per_day,
       ROUND(1000 * PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY units_per_day)::numeric) AS same_in_litres_if_m3
FROM per_meter GROUP BY site ORDER BY site;

\echo '== P8. First look at problems we will flag in Step 3'
WITH d AS (
    SELECT site,
           reading_m3 - LAG(reading_m3) OVER (PARTITION BY meter_key ORDER BY read_ts) AS step
    FROM raw_readings
)
SELECT site,
       COUNT(*) FILTER (WHERE step < 0)   AS negative_steps,
       COUNT(*) FILTER (WHERE step > 5)   AS steps_over_5,
       ROUND(100.0 * COUNT(*) FILTER (WHERE step = 0) / COUNT(step), 1) AS pct_zero_steps,
       MAX(step) AS largest_step
FROM d GROUP BY site ORDER BY site;
