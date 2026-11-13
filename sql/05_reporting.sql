/* =====================================================================
   05_reporting.sql  -  Step 4: build the reporting layer for Power BI
   Run from psql:  \i C:/smart-meter-reporting/sql/05_reporting.sql
   Needs:   meters, raw_households, clean_intervals, dq_rules, dq_flags
   Creates schema rpt with:
       rpt.dim_date                one row per calendar day
       rpt.dim_hour                one row per hour of the day
       rpt.dim_property            one row per meter/property
       rpt.dim_dq_flag             one row per data quality rule
       rpt.fact_hourly_consumption litres per property per hour (hourly meters)
       rpt.fact_daily_consumption  litres per property per day (all meters)
       rpt.fact_dq_flags           flag counts per property per day per type
   Power BI connects to the rpt schema only.

   Why tables and not views: the hourly fact aggregates 5.6 million
   intervals. As a view, that work would repeat on every Power BI
   refresh. Building it once here keeps refresh fast; the script is
   simply re-run when the source data changes. Every table and column
   carries a COMMENT, which is the data dictionary for the README.
   ===================================================================== */
\set ON_ERROR_STOP on
\timing on

DROP SCHEMA IF EXISTS rpt CASCADE;
CREATE SCHEMA rpt;

/* ---------------------------------------------------------------------
   1. dim_date: Northern Hemisphere meteorological seasons
      (Winter = Dec-Feb, Spring = Mar-May, Summer = Jun-Aug, Autumn = Sep-Nov)
   --------------------------------------------------------------------- */
CREATE TABLE rpt.dim_date AS
SELECT TO_CHAR(d, 'YYYYMMDD')::int                    AS date_key,
       d::date                                        AS date,
       EXTRACT(YEAR FROM d)::int                      AS year,
       EXTRACT(MONTH FROM d)::int                     AS month_num,
       TO_CHAR(d, 'Mon')                              AS month_name,
       DATE_TRUNC('month', d)::date                   AS month_start,
       TO_CHAR(d, 'YYYY-MM')                          AS year_month,
       EXTRACT(ISODOW FROM d)::int                    AS weekday_num,      -- 1 = Monday
       TO_CHAR(d, 'Dy')                               AS weekday_name,
       EXTRACT(ISODOW FROM d) IN (6, 7)               AS is_weekend,
       CASE WHEN EXTRACT(MONTH FROM d) IN (12, 1, 2) THEN 'Winter'
            WHEN EXTRACT(MONTH FROM d) IN (3, 4, 5)  THEN 'Spring'
            WHEN EXTRACT(MONTH FROM d) IN (6, 7, 8)  THEN 'Summer'
            ELSE 'Autumn' END                         AS season,
       CASE WHEN EXTRACT(MONTH FROM d) IN (12, 1, 2) THEN 1
            WHEN EXTRACT(MONTH FROM d) IN (3, 4, 5)  THEN 2
            WHEN EXTRACT(MONTH FROM d) IN (6, 7, 8)  THEN 3
            ELSE 4 END                                AS season_sort
FROM GENERATE_SERIES(DATE '2014-10-01', DATE '2017-04-30', INTERVAL '1 day') AS d;
ALTER TABLE rpt.dim_date ADD PRIMARY KEY (date_key);
COMMENT ON TABLE rpt.dim_date IS 'Calendar, one row per day, Oct 2014 to Apr 2017. Seasons are meteorological (Summer = Jun-Aug).';

/* ---------------------------------------------------------------------
   2. dim_hour
   --------------------------------------------------------------------- */
CREATE TABLE rpt.dim_hour AS
SELECT h                                           AS hour,
       LPAD(h::text, 2, '0') || ':00'              AS hour_label,
       CASE WHEN h < 6  THEN 'Night (00-06)'
            WHEN h < 12 THEN 'Morning (06-12)'
            WHEN h < 18 THEN 'Afternoon (12-18)'
            ELSE 'Evening (18-24)' END             AS day_period,
       h IN (2, 3)                                 AS is_night_window
FROM GENERATE_SERIES(0, 23) AS h;
ALTER TABLE rpt.dim_hour ADD PRIMARY KEY (hour);
COMMENT ON TABLE rpt.dim_hour IS 'Hour of day. is_night_window marks 02:00-04:00, used for the night use share.';

/* ---------------------------------------------------------------------
   3. Hourly fact (hourly meters only). An hour that was quarantined has
      NO row; it is never stored as zero, so missing data cannot pass for
      no use.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE meter_ids AS
SELECT ROW_NUMBER() OVER (ORDER BY site, smart_meter_id)::int AS meter_id, meter_key
FROM meters;

CREATE TABLE rpt.fact_hourly_consumption AS
SELECT mi.meter_id,
       TO_CHAR(c.hour_start, 'YYYYMMDD')::int     AS date_key,
       EXTRACT(HOUR FROM c.hour_start)::int       AS hour,
       ROUND(SUM(c.litres), 1)                    AS litres
FROM clean_intervals c
JOIN meters m     USING (meter_key)
JOIN meter_ids mi USING (meter_key)
WHERE m.cadence = 'Hourly' AND c.hour_start IS NOT NULL
GROUP BY mi.meter_id, c.hour_start;
ALTER TABLE rpt.fact_hourly_consumption ADD PRIMARY KEY (meter_id, date_key, hour);
COMMENT ON TABLE  rpt.fact_hourly_consumption IS 'Clean litres per property per hour. Hourly meters only. Quarantined hours have no row.';
COMMENT ON COLUMN rpt.fact_hourly_consumption.litres IS 'Litres used in the hour, from clean intervals placed by their midpoint.';

/* ---------------------------------------------------------------------
   4. Daily fact (all meters).
      coverage_hours = hours of clean data behind the day's total.
      is_complete_day = 22 to 26 hours of coverage (allows for daylight
      saving days). Averages use complete days only, so a day with half
      its data quarantined does not look like a low-use day.
      Continuous flow day = complete hourly day where EVERY hour used
      water (min hour > 0). Meters measure to 1 litre, so this means at
      least 1 L in every single hour, night included.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE hourly_by_day AS
SELECT meter_id, date_key,
       COUNT(*)                                            AS hours_recorded,
       MIN(litres)                                         AS min_hour_litres,
       SUM(litres) FILTER (WHERE hour IN (2, 3))           AS night_litres
FROM rpt.fact_hourly_consumption
GROUP BY meter_id, date_key;

CREATE TABLE rpt.fact_daily_consumption AS
WITH d AS (
    SELECT mi.meter_id,
           TO_CHAR(c.read_date, 'YYYYMMDD')::int        AS date_key,
           SUM(c.litres)                                AS litres,
           SUM(c.gap_s) / 3600.0                        AS coverage_hours
    FROM clean_intervals c
    JOIN meter_ids mi USING (meter_key)
    WHERE c.read_date IS NOT NULL
    GROUP BY mi.meter_id, c.read_date
)
SELECT d.meter_id,
       d.date_key,
       ROUND(d.litres, 1)                                         AS litres,
       ROUND(d.coverage_hours, 2)                                 AS coverage_hours,
       d.coverage_hours BETWEEN 22 AND 26                         AS is_complete_day,
       h.hours_recorded,
       h.min_hour_litres,
       ROUND(h.night_litres, 1)                                   AS night_litres,
       (h.hours_recorded >= 23 AND h.min_hour_litres > 0)         AS is_continuous_flow_day
FROM d
LEFT JOIN hourly_by_day h USING (meter_id, date_key);
ALTER TABLE rpt.fact_daily_consumption ADD PRIMARY KEY (meter_id, date_key);
COMMENT ON TABLE  rpt.fact_daily_consumption IS 'Clean litres per property per day, all meters.';
COMMENT ON COLUMN rpt.fact_daily_consumption.coverage_hours IS 'Hours of clean data behind the daily total.';
COMMENT ON COLUMN rpt.fact_daily_consumption.is_complete_day IS 'True when coverage is 22-26 hours. Use for averages.';
COMMENT ON COLUMN rpt.fact_daily_consumption.night_litres IS 'Litres used 02:00-04:00 (hourly meters only).';
COMMENT ON COLUMN rpt.fact_daily_consumption.is_continuous_flow_day IS 'Hourly meters: 23+ hours recorded and every hour used at least 1 litre.';

/* ---------------------------------------------------------------------
   5. dim_property: one row per meter, with household features flattened
      (MAX per meter, because the household file repeats each meter once
      per appliance and some repeats are blank), quality scores and the
      continuous flow status.
   --------------------------------------------------------------------- */
CREATE TABLE rpt.dim_property AS
WITH hh AS (
    SELECT meter_key,
           MAX(NULLIF(NULLIF(residency_type,   'NULL'), '\N'))                              AS residency_type,
           MAX(REPLACE(NULLIF(NULLIF(household_garden,  'NULL'), '\N'), ',', '.')::numeric) AS garden,
           MAX(REPLACE(NULLIF(NULLIF(household_pool,    'NULL'), '\N'), ',', '.')::numeric) AS pool,
           MAX(REPLACE(NULLIF(NULLIF(irrigation_system, 'NULL'), '\N'), ',', '.')::numeric) AS irrigation,
           MAX(REPLACE(NULLIF(NULLIF(household_size,    'NULL'), '\N'), ',', '.')::numeric) AS size_m2,
           MAX(REPLACE(NULLIF(NULLIF(household_garden_area, 'NULL'), '\N'), ',', '.')::numeric) AS garden_m2,
           MAX(REPLACE(NULLIF(NULLIF(number_bathrooms,  'NULL'), '\N'), ',', '.')::numeric) AS bathrooms,
           MAX(NULLIF(NULLIF(environmental_attitude, 'NULL'), '\N'))                        AS env_attitude
    FROM raw_households GROUP BY meter_key
),
reads AS (   -- read completeness: share of expected hours (or days) that received a read
    SELECT r.meter_key,
           CASE WHEN m.cadence = 'Hourly'
                THEN COUNT(DISTINCT DATE_TRUNC('hour', r.read_ts))::numeric
                     / NULLIF(EXTRACT(EPOCH FROM m.last_read - m.first_read) / 3600 + 1, 0)
                ELSE COUNT(DISTINCT r.read_ts::date)::numeric
                     / NULLIF(m.last_read::date - m.first_read::date + 1, 0)
           END AS completeness
    FROM raw_readings r JOIN meters m USING (meter_key)
    GROUP BY r.meter_key, m.cadence, m.first_read, m.last_read
),
cleanshare AS (
    SELECT i.meter_key, COUNT(c.interval_id)::numeric / COUNT(*) AS clean_share
    FROM reading_intervals i LEFT JOIN clean_intervals c USING (interval_id)
    GROUP BY i.meter_key
),
cf AS (
    SELECT meter_id,
           COUNT(*) FILTER (WHERE hours_recorded >= 23)           AS complete_hourly_days,
           COUNT(*) FILTER (WHERE is_continuous_flow_day)         AS continuous_flow_days
    FROM rpt.fact_daily_consumption GROUP BY meter_id
)
SELECT mi.meter_id,
       m.meter_key,
       m.site,
       CASE m.site WHEN 'TEG' THEN 'Tegna (CH)' ELSE 'Valencia (ES)' END       AS site_name,
       m.cadence,
       m.first_read::date                                                       AS first_read_date,
       m.last_read::date                                                        AS last_read_date,
       hh.residency_type IS NOT NULL                                            AS has_household_features,
       CASE WHEN hh.residency_type = 'Flat' THEN 'Flat'
            WHEN hh.residency_type IN ('House', 'Single Family') THEN 'House'
            WHEN hh.residency_type IS NOT NULL THEN 'Other'
            ELSE 'Not recorded' END                                             AS property_type,
       CASE WHEN hh.garden IS NULL THEN 'Not recorded' WHEN hh.garden = 1 THEN 'Garden' ELSE 'No garden' END                    AS garden,
       CASE WHEN hh.pool IS NULL THEN 'Not recorded' WHEN hh.pool = 1 THEN 'Pool' ELSE 'No pool' END                            AS pool,
       CASE WHEN hh.irrigation IS NULL THEN 'Not recorded' WHEN hh.irrigation = 1 THEN 'Irrigation' ELSE 'No irrigation' END    AS irrigation,
       hh.size_m2                                                               AS household_size_m2,
       hh.garden_m2                                                             AS garden_area_m2,
       hh.bathrooms,
       hh.env_attitude                                                          AS environmental_attitude,
       ROUND(LEAST(rd.completeness, 1) * 100, 1)                                AS read_completeness_pct,
       ROUND(cs.clean_share * 100, 1)                                           AS clean_interval_pct,
       LEAST(rd.completeness, 1) < 0.9                                          AS below_90pct_completeness,
       COALESCE(cf.complete_hourly_days, 0)                                     AS complete_hourly_days,
       COALESCE(cf.continuous_flow_days, 0)                                     AS continuous_flow_days,
       ROUND(100.0 * cf.continuous_flow_days / NULLIF(cf.complete_hourly_days, 0), 1) AS continuous_flow_pct,
       CASE WHEN m.cadence <> 'Hourly' OR COALESCE(cf.complete_hourly_days, 0) < 30 THEN 'Not assessed'
            WHEN cf.continuous_flow_days >= 7
             AND cf.continuous_flow_days >= 0.5 * cf.complete_hourly_days         THEN 'Persistent'
            WHEN cf.continuous_flow_days >= 7
             AND cf.continuous_flow_days >= 0.1 * cf.complete_hourly_days         THEN 'Intermittent'
            ELSE 'None or rare' END                                             AS continuous_flow_status
FROM meters m
JOIN meter_ids mi        USING (meter_key)
LEFT JOIN hh             USING (meter_key)
LEFT JOIN reads rd       USING (meter_key)
LEFT JOIN cleanshare cs  USING (meter_key)
LEFT JOIN cf             ON cf.meter_id = mi.meter_id;
ALTER TABLE rpt.dim_property ADD PRIMARY KEY (meter_id);
COMMENT ON TABLE  rpt.dim_property IS 'One row per property (meter) with household features, data quality scores and continuous flow status.';
COMMENT ON COLUMN rpt.dim_property.read_completeness_pct IS 'Share of expected hours (hourly meters) or days (other meters) between first and last read that received at least one read.';
COMMENT ON COLUMN rpt.dim_property.clean_interval_pct IS 'Share of the meter''s intervals that passed every quarantine rule.';
COMMENT ON COLUMN rpt.dim_property.continuous_flow_status IS 'Persistent: continuous flow on 50%+ of complete days (min 7 days). Intermittent: 10-50%. Not assessed: not an hourly meter or under 30 complete days. A flag to investigate, not proof of a leak.';

/* ---------------------------------------------------------------------
   6. Data quality for reporting
   --------------------------------------------------------------------- */
CREATE TABLE rpt.dim_dq_flag AS
SELECT flag_type, sort_order, description, threshold, action, quarantined FROM dq_rules;
ALTER TABLE rpt.dim_dq_flag ADD PRIMARY KEY (flag_type);
COMMENT ON TABLE rpt.dim_dq_flag IS 'Data quality rules: definition, threshold and action. Feeds the definitions panel.';

CREATE TABLE rpt.fact_dq_flags AS
SELECT mi.meter_id,
       TO_CHAR(f.start_ts, 'YYYYMMDD')::int  AS date_key,
       f.flag_type,
       COUNT(*)                              AS flag_count
FROM dq_flags f JOIN meter_ids mi USING (meter_key)
GROUP BY mi.meter_id, TO_CHAR(f.start_ts, 'YYYYMMDD')::int, f.flag_type;
COMMENT ON TABLE rpt.fact_dq_flags IS 'Number of data quality flags per property per day per flag type.';

ANALYZE rpt.dim_date; ANALYZE rpt.dim_hour; ANALYZE rpt.dim_property; ANALYZE rpt.dim_dq_flag;
ANALYZE rpt.fact_hourly_consumption; ANALYZE rpt.fact_daily_consumption; ANALYZE rpt.fact_dq_flags;

/* =====================================================================
   Checks and a first look at the five business questions
   ===================================================================== */

\echo '== R1. Row counts'
SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM rpt.dim_date
UNION ALL SELECT 'dim_hour', COUNT(*) FROM rpt.dim_hour
UNION ALL SELECT 'dim_property', COUNT(*) FROM rpt.dim_property
UNION ALL SELECT 'dim_dq_flag', COUNT(*) FROM rpt.dim_dq_flag
UNION ALL SELECT 'fact_hourly_consumption', COUNT(*) FROM rpt.fact_hourly_consumption
UNION ALL SELECT 'fact_daily_consumption', COUNT(*) FROM rpt.fact_daily_consumption
UNION ALL SELECT 'fact_dq_flags', COUNT(*) FROM rpt.fact_dq_flags;

\echo '== R2. Reconciliation: facts = clean intervals (difference should be 0, rounding aside)'
SELECT 'daily' AS fact,
       ROUND((SELECT SUM(litres) FROM clean_intervals WHERE read_date IS NOT NULL))          AS clean_litres,
       ROUND((SELECT SUM(litres) FROM rpt.fact_daily_consumption))                           AS fact_litres,
       ROUND((SELECT SUM(litres) FROM clean_intervals WHERE read_date IS NOT NULL)
           - (SELECT SUM(litres) FROM rpt.fact_daily_consumption))                           AS difference
UNION ALL
SELECT 'hourly',
       ROUND((SELECT SUM(c.litres) FROM clean_intervals c JOIN meters m USING (meter_key)
              WHERE m.cadence = 'Hourly' AND c.hour_start IS NOT NULL)),
       ROUND((SELECT SUM(litres) FROM rpt.fact_hourly_consumption)),
       ROUND((SELECT SUM(c.litres) FROM clean_intervals c JOIN meters m USING (meter_key)
              WHERE m.cadence = 'Hourly' AND c.hour_start IS NOT NULL)
           - (SELECT SUM(litres) FROM rpt.fact_hourly_consumption));

\echo '== Q1. Use per property: average of each property''s mean daily litres (complete days)'
WITH p AS (
    SELECT p.site_name, f.meter_id, AVG(f.litres) AS avg_day
    FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
    WHERE f.is_complete_day GROUP BY p.site_name, f.meter_id HAVING COUNT(*) >= 30
)
SELECT site_name, COUNT(*) AS properties,
       ROUND(AVG(avg_day)) AS avg_litres_per_property_day,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_day)::numeric) AS median_property
FROM p GROUP BY site_name ORDER BY site_name;

\echo '== Q1b. Seasonal profile (complete days)'
SELECT p.site_name, d.season, ROUND(AVG(f.litres)) AS avg_litres_per_property_day
FROM rpt.fact_daily_consumption f
JOIN rpt.dim_property p USING (meter_id) JOIN rpt.dim_date d USING (date_key)
WHERE f.is_complete_day
GROUP BY p.site_name, d.season, d.season_sort ORDER BY p.site_name, d.season_sort;

\echo '== Q2. Hourly demand profile: peak hour and peak-to-average ratio'
WITH prof AS (
    SELECT p.site_name, h.hour, AVG(h.litres) AS avg_litres
    FROM rpt.fact_hourly_consumption h JOIN rpt.dim_property p USING (meter_id)
    GROUP BY p.site_name, h.hour
)
SELECT site_name,
       (ARRAY_AGG(hour ORDER BY avg_litres DESC))[1]           AS peak_hour,
       ROUND(MAX(avg_litres), 1)                               AS peak_litres_per_property_hour,
       ROUND(AVG(avg_litres), 1)                               AS average_litres_per_property_hour,
       ROUND(MAX(avg_litres) / AVG(avg_litres), 2)             AS peak_to_average,
       (ARRAY_AGG(hour ORDER BY avg_litres))[1]                AS quietest_hour
FROM prof GROUP BY site_name ORDER BY site_name;

\echo '== Q3. Continuous flow status (hourly meters)'
SELECT site_name, continuous_flow_status, COUNT(*) AS properties
FROM rpt.dim_property GROUP BY site_name, continuous_flow_status ORDER BY site_name, properties DESC;

\echo '== Q3b. Night use share (02:00-04:00) by continuous flow status, complete hourly days'
SELECT p.continuous_flow_status,
       ROUND(100.0 * SUM(f.night_litres) / NULLIF(SUM(f.litres), 0), 1) AS night_share_pct,
       ROUND(AVG(f.litres)) AS avg_litres_per_day
FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
WHERE f.hours_recorded >= 23
GROUP BY p.continuous_flow_status ORDER BY night_share_pct DESC;

\echo '== Q4. Household features (indicative: small groups, see counts)'
SELECT feature, value, COUNT(DISTINCT meter_id) AS properties, ROUND(AVG(litres)) AS avg_litres_per_property_day
FROM (
    SELECT 'Property type' AS feature, p.property_type AS value, f.meter_id, f.litres
    FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
    WHERE f.is_complete_day AND p.has_household_features
    UNION ALL
    SELECT 'Garden', p.garden, f.meter_id, f.litres
    FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
    WHERE f.is_complete_day AND p.garden <> 'Not recorded'
    UNION ALL
    SELECT 'Pool', p.pool, f.meter_id, f.litres
    FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
    WHERE f.is_complete_day AND p.pool <> 'Not recorded'
    UNION ALL
    SELECT 'Irrigation', p.irrigation, f.meter_id, f.litres
    FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id)
    WHERE f.is_complete_day AND p.irrigation <> 'Not recorded'
) x
GROUP BY feature, value ORDER BY feature, value;

\echo '== Q5. Data quality: properties below 90% read completeness'
SELECT site_name, cadence, COUNT(*) AS properties,
       COUNT(*) FILTER (WHERE below_90pct_completeness) AS below_90pct,
       ROUND(AVG(read_completeness_pct), 1) AS avg_completeness_pct,
       ROUND(AVG(clean_interval_pct), 1)    AS avg_clean_pct
FROM rpt.dim_property GROUP BY site_name, cadence ORDER BY site_name, cadence;
