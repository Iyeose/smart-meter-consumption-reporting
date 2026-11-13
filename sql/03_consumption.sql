/* =====================================================================
   03_consumption.sql  -  Step 2: turn cumulative reads into consumption
   Run from psql:  \i C:/smart-meter-reporting/sql/03_consumption.sql
   Needs: raw_readings and meters (Step 1)
   Creates: reading_intervals (one row per pair of consecutive reads)
   ===================================================================== */
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS reading_intervals CASCADE;

/* ---------------------------------------------------------------------
   How it works
   1. dedup:  one read per meter per timestamp. Where a timestamp repeats
              we keep the last row in the file (highest source_row).
              The duplicates themselves get a data quality flag in Step 3.
   2. paired: LAG() looks back to the previous read of the SAME meter
              (PARTITION BY meter_key) in time order (ORDER BY read_ts).
              Consumption = this reading - previous reading.
   3. Each interval is placed in an hour and a day by its MIDPOINT.
              A read at 10:00 followed by one at 11:00 has its midpoint at
              10:30, so the water belongs to the 10:00-11:00 hour. The same
              rule works for daily meters read at 00:05: the midpoint falls
              at noon, so the water belongs to that day.
   4. Intervals too long to place honestly are left unallocated:
              - hour_start only when the gap is 90 minutes or less
              - read_date  only when the gap is 36 hours or less
              Spreading a 3-day gap evenly would invent a smooth profile
              that never happened, and would hide night-time zeros that
              the leak check depends on. These intervals become "gap"
              flags in Step 3; their litres stay in this table so the
              Excel reconciliation in Step 5 still balances.
   --------------------------------------------------------------------- */
CREATE TABLE reading_intervals AS
WITH dedup AS (
    SELECT DISTINCT ON (meter_key, read_ts)
           site, meter_key, read_ts, reading_m3, source_row
    FROM raw_readings
    ORDER BY meter_key, read_ts, source_row DESC
),
paired AS (
    SELECT site,
           meter_key,
           LAG(read_ts)    OVER w AS prev_ts,
           read_ts,
           LAG(reading_m3) OVER w AS prev_reading_m3,
           reading_m3,
           source_row
    FROM dedup
    WINDOW w AS (PARTITION BY meter_key ORDER BY read_ts)
)
SELECT p.site,
       p.meter_key,
       m.cadence,
       p.prev_ts,
       p.read_ts,
       EXTRACT(EPOCH FROM p.read_ts - p.prev_ts)::int          AS gap_s,
       p.prev_reading_m3,
       p.reading_m3,
       p.reading_m3 - p.prev_reading_m3                         AS delta_m3,
       (p.reading_m3 - p.prev_reading_m3) * 1000                AS litres,
       p.prev_ts + (p.read_ts - p.prev_ts) / 2                  AS mid_ts,
       CASE WHEN p.read_ts - p.prev_ts <= INTERVAL '90 minutes'
            THEN date_trunc('hour', p.prev_ts + (p.read_ts - p.prev_ts) / 2) END AS hour_start,
       CASE WHEN p.read_ts - p.prev_ts <= INTERVAL '36 hours'
            THEN (p.prev_ts + (p.read_ts - p.prev_ts) / 2)::date END            AS read_date,
       p.source_row
FROM paired p
JOIN meters m USING (meter_key)
WHERE p.prev_ts IS NOT NULL;          -- a meter's first read has nothing to subtract from

ALTER TABLE reading_intervals ADD COLUMN interval_id bigserial PRIMARY KEY;
CREATE INDEX ix_intervals_meter_ts ON reading_intervals (meter_key, read_ts);
CREATE INDEX ix_intervals_hour     ON reading_intervals (meter_key, hour_start);
ANALYZE reading_intervals;

/* =====================================================================
   Checks - copy the output into docs/step2_note.md
   ===================================================================== */

\echo '== C1. Rows: reads in, duplicates removed, intervals out'
SELECT r.site,
       r.reads,
       r.reads - d.distinct_reads                       AS duplicate_reads_removed,
       r.meters                                         AS first_reads_with_no_interval,
       i.intervals,
       (r.reads - (r.reads - d.distinct_reads) - r.meters) = i.intervals AS balances
FROM (SELECT site, COUNT(*) reads, COUNT(DISTINCT meter_key) meters FROM raw_readings GROUP BY site) r
JOIN (SELECT site, COUNT(*) distinct_reads FROM (SELECT DISTINCT site, meter_key, read_ts FROM raw_readings) x GROUP BY site) d USING (site)
JOIN (SELECT site, COUNT(*) intervals FROM reading_intervals GROUP BY site) i USING (site)
ORDER BY r.site;

\echo '== C2. Every meter has consumption rows'
SELECT m.site,
       COUNT(*)                                         AS meters,
       COUNT(*) FILTER (WHERE i.n IS NULL)              AS meters_without_intervals
FROM meters m
LEFT JOIN (SELECT meter_key, COUNT(*) n FROM reading_intervals GROUP BY meter_key) i USING (meter_key)
GROUP BY m.site ORDER BY m.site;

\echo '== C3. Telescoping check: sum of deltas = last reading - first reading'
-- Because each delta is "this minus previous", adding them all up must give
-- last minus first for every meter. Any meter listed here means an error.
WITH ends AS (
    SELECT DISTINCT ON (meter_key) meter_key,
           FIRST_VALUE(prev_reading_m3) OVER (PARTITION BY meter_key ORDER BY read_ts)      AS first_reading,
           LAST_VALUE(reading_m3)       OVER (PARTITION BY meter_key ORDER BY read_ts
                                              ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_reading
    FROM reading_intervals
), sums AS (
    SELECT meter_key, SUM(delta_m3) AS total_delta FROM reading_intervals GROUP BY meter_key
)
SELECT COUNT(*)                                                    AS meters_checked,
       COUNT(*) FILTER (WHERE s.total_delta <> e.last_reading - e.first_reading) AS meters_failing
FROM sums s JOIN ends e USING (meter_key);

\echo '== C4. How much of the data can be placed in an hour and a day'
SELECT site, cadence,
       COUNT(*)                                                             AS intervals,
       ROUND(100.0 * COUNT(hour_start) / COUNT(*), 1)                       AS pct_placed_in_hour,
       ROUND(100.0 * COUNT(read_date)  / COUNT(*), 1)                       AS pct_placed_in_day,
       COUNT(*) FILTER (WHERE read_date IS NULL)                            AS unallocated_long_gaps
FROM reading_intervals
GROUP BY site, cadence ORDER BY site, cadence;

\echo '== C5. Before cleaning: why we need Step 3'
-- Daily litres per meter, before any flags. Compare the median with the
-- mean and the maximum: a handful of resets and spikes wreck the average.
WITH daily AS (
    SELECT site, meter_key, read_date, SUM(litres) AS litres
    FROM reading_intervals
    WHERE read_date IS NOT NULL
    GROUP BY site, meter_key, read_date
)
SELECT site,
       COUNT(*)                                                       AS meter_days,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY litres)::numeric) AS median_litres_per_day,
       ROUND(AVG(litres))                                             AS mean_litres_per_day,
       ROUND(MIN(litres))                                             AS min_litres_per_day,
       ROUND(MAX(litres))                                             AS max_litres_per_day,
       COUNT(*) FILTER (WHERE litres < 0)                             AS negative_days
FROM daily GROUP BY site ORDER BY site;

\echo '== C6. Daylight saving check (Tegna): reads are in local time'
SELECT read_ts, gap_s / 3600.0 AS gap_hours, COUNT(*) AS meters
FROM reading_intervals
WHERE site = 'TEG' AND read_ts::date IN ('2015-03-29', '2015-10-25')
  AND gap_s > 3600 AND gap_s <= 3 * 3600
GROUP BY read_ts, gap_s ORDER BY meters DESC LIMIT 4;
