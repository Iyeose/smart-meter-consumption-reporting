/* =====================================================================
   04_dq_flags.sql  -  Step 3: flag data quality issues and quarantine
   Run from psql:  \i C:/smart-meter-reporting/sql/04_dq_flags.sql
   Needs:   raw_readings, meters, reading_intervals (Steps 1-2)
   Creates: dq_rules        one row per rule, with its threshold and action
            dq_flags        one row per issue found
            clean_intervals reading_intervals minus quarantined rows
   Nothing is deleted: reading_intervals still holds every interval.
   ===================================================================== */
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS dq_rules, dq_flags, clean_intervals CASCADE;

/* ---------------------------------------------------------------------
   1. The rules. Thresholds were chosen from the profiling (see the
   step 3 note) and live in one table so the README, Excel and the
   Power BI definitions panel all quote the same numbers.
   --------------------------------------------------------------------- */
CREATE TABLE dq_rules (
    flag_type    text PRIMARY KEY,
    sort_order   int,
    description  text,
    threshold    text,
    action       text,
    quarantined  boolean
);

INSERT INTO dq_rules VALUES
('DUPLICATE_TS', 1, 'Same meter has more than one read at the same timestamp',
 'Any repeat', 'Last row in the file kept, others removed before calculating consumption', false),
('NEGATIVE',     2, 'Reading went down. A cumulative meter cannot run backwards, so this is a reset, a replacement, a bad read or reverse flow',
 'Change < 0 litres', 'Quarantined', true),
('REBOUND',      3, 'Reading jumps back up straight after a NEGATIVE step, to at least where it was before the drop. Counting it would add water that was never used',
 'Next interval after a NEGATIVE that recovers the drop', 'Quarantined', true),
('SPIKE',        4, 'Flow faster than a household supply can deliver',
 'More than 3,000 litres per hour (intervals under 1 hour are treated as 1 hour)', 'Quarantined', true),
('GAP_LONG',     5, 'Reads too far apart to say when the water was used',
 'Gap over 36 hours', 'Quarantined (litres cannot be placed in a day)', true),
('GAP_HOURLY',   6, 'Hourly meter missed one or more reads',
 'Hourly meter, gap over 90 minutes and up to 36 hours', 'Kept in daily totals, left out of hourly tables', false),
('ZERO_RUN',     7, 'No flow at all for two weeks or more: a stuck meter or an empty property (the data cannot tell which)',
 '14 days or more of unbroken zero change', 'Quarantined, so averages describe properties in use', true);

/* ---------------------------------------------------------------------
   2. The flags table: one row per issue, with the reason.
   An interval can carry more than one flag (e.g. a SPIKE that is also
   a REBOUND); totals by litres therefore use clean_intervals, not a
   sum over dq_flags.
   --------------------------------------------------------------------- */
CREATE TABLE dq_flags (
    flag_id         bigserial PRIMARY KEY,
    site            text,
    meter_key       text,
    interval_id     bigint,        -- NULL for DUPLICATE_TS (the row never became an interval)
    flag_type       text REFERENCES dq_rules (flag_type),
    start_ts        timestamp,
    end_ts          timestamp,
    litres          numeric,
    detail          text
);

-- 2a. DUPLICATE_TS: one flag per extra copy
INSERT INTO dq_flags (site, meter_key, flag_type, start_ts, end_ts, detail)
SELECT site, meter_key, 'DUPLICATE_TS', read_ts, read_ts,
       copies || ' reads at this timestamp' ||
       CASE WHEN distinct_values > 1 THEN ', values disagree' ELSE ', values identical' END
FROM (
    SELECT site, meter_key, read_ts, COUNT(*) AS copies, COUNT(DISTINCT reading_m3) AS distinct_values
    FROM raw_readings GROUP BY site, meter_key, read_ts HAVING COUNT(*) > 1
) d;

-- 2b. NEGATIVE
INSERT INTO dq_flags (site, meter_key, interval_id, flag_type, start_ts, end_ts, litres, detail)
SELECT site, meter_key, interval_id, 'NEGATIVE', prev_ts, read_ts, litres,
       CASE WHEN litres > -10 THEN 'Small drop (under 10 L): meter jitter or reverse flow'
            ELSE 'Large drop: reset, replacement or bad read' END
FROM reading_intervals
WHERE delta_m3 < 0;

-- 2c. REBOUND: the interval straight after a NEGATIVE, if it climbs back
WITH nxt AS (
    SELECT interval_id, site, meter_key, prev_ts, read_ts, litres, reading_m3,
           LAG(delta_m3)        OVER w AS prev_delta,
           LAG(prev_reading_m3) OVER w AS level_before_drop
    FROM reading_intervals
    WINDOW w AS (PARTITION BY meter_key ORDER BY read_ts)
)
INSERT INTO dq_flags (site, meter_key, interval_id, flag_type, start_ts, end_ts, litres, detail)
SELECT site, meter_key, interval_id, 'REBOUND', prev_ts, read_ts, litres,
       'Recovers a drop of ' || ROUND(-prev_delta * 1000) || ' L in the previous interval'
FROM nxt
WHERE prev_delta < 0 AND reading_m3 >= level_before_drop;

-- 2d. SPIKE
INSERT INTO dq_flags (site, meter_key, interval_id, flag_type, start_ts, end_ts, litres, detail)
SELECT site, meter_key, interval_id, 'SPIKE', prev_ts, read_ts, litres,
       ROUND(litres / GREATEST(gap_s / 3600.0, 1)) || ' L/h'
FROM reading_intervals
WHERE litres > 3000 * GREATEST(gap_s / 3600.0, 1);

-- 2e. GAP_LONG and GAP_HOURLY
INSERT INTO dq_flags (site, meter_key, interval_id, flag_type, start_ts, end_ts, litres, detail)
SELECT site, meter_key, interval_id,
       CASE WHEN gap_s > 36 * 3600 THEN 'GAP_LONG' ELSE 'GAP_HOURLY' END,
       prev_ts, read_ts, litres,
       ROUND(gap_s / 3600.0, 1) || ' hours between reads'
FROM reading_intervals
WHERE gap_s > 36 * 3600
   OR (cadence = 'Hourly' AND gap_s > 90 * 60);

-- 2f. ZERO_RUN: "gaps and islands". Consecutive zero intervals share the
--     same difference between two ROW_NUMBER()s, which gives each run an id.
WITH z AS (
    SELECT interval_id, site, meter_key, prev_ts, read_ts, gap_s, delta_m3 = 0 AS is_zero,
           ROW_NUMBER() OVER (PARTITION BY meter_key ORDER BY read_ts)
         - ROW_NUMBER() OVER (PARTITION BY meter_key, delta_m3 = 0 ORDER BY read_ts) AS run_id
    FROM reading_intervals
), runs AS (
    SELECT meter_key, run_id, SUM(gap_s) / 86400.0 AS run_days,
           MIN(prev_ts) AS run_start, MAX(read_ts) AS run_end
    FROM z WHERE is_zero GROUP BY meter_key, run_id
    HAVING SUM(gap_s) >= 14 * 86400
)
INSERT INTO dq_flags (site, meter_key, interval_id, flag_type, start_ts, end_ts, litres, detail)
SELECT z.site, z.meter_key, z.interval_id, 'ZERO_RUN', z.prev_ts, z.read_ts, 0,
       'Part of a ' || ROUND(r.run_days) || '-day run with no flow (' ||
       r.run_start::date || ' to ' || r.run_end::date || ')'
FROM z JOIN runs r USING (meter_key, run_id)
WHERE z.is_zero;

CREATE INDEX ix_dq_flags_interval ON dq_flags (interval_id);
CREATE INDEX ix_dq_flags_meter    ON dq_flags (meter_key, flag_type);
ANALYZE dq_flags;

/* ---------------------------------------------------------------------
   3. clean_intervals: every interval with no quarantining flag.
   This is what Step 4's reporting views read from.
   --------------------------------------------------------------------- */
CREATE TABLE clean_intervals AS
SELECT i.*
FROM reading_intervals i
WHERE NOT EXISTS (
    SELECT 1 FROM dq_flags f JOIN dq_rules r USING (flag_type)
    WHERE f.interval_id = i.interval_id AND r.quarantined
);
ALTER TABLE clean_intervals ADD PRIMARY KEY (interval_id);
CREATE INDEX ix_clean_meter_hour ON clean_intervals (meter_key, hour_start);
CREATE INDEX ix_clean_meter_date ON clean_intervals (meter_key, read_date);
ANALYZE clean_intervals;

/* =====================================================================
   Checks - copy the output into docs/step3_note.md
   ===================================================================== */

\echo '== D1. Flags by type'
SELECT r.sort_order, f.flag_type, f.site,
       COUNT(*)                         AS flags,
       COUNT(DISTINCT f.meter_key)      AS meters_affected,
       ROUND(SUM(f.litres))             AS litres_in_flagged_intervals,
       r.action
FROM dq_flags f JOIN dq_rules r USING (flag_type)
GROUP BY r.sort_order, f.flag_type, f.site, r.action
ORDER BY r.sort_order, f.site;

\echo '== D2. Quarantine balances: all intervals = clean + quarantined'
SELECT a.site,
       a.intervals                         AS all_intervals,
       c.intervals                         AS clean_intervals,
       a.intervals - c.intervals           AS quarantined_intervals,
       ROUND(100.0 * c.intervals / a.intervals, 2) AS pct_clean,
       ROUND(a.litres)                     AS all_litres,
       ROUND(c.litres)                     AS clean_litres,
       ROUND(a.litres - c.litres)          AS quarantined_litres
FROM (SELECT site, COUNT(*) intervals, SUM(litres) litres FROM reading_intervals GROUP BY site) a
JOIN (SELECT site, COUNT(*) intervals, SUM(litres) litres FROM clean_intervals   GROUP BY site) c USING (site)
ORDER BY a.site;

\echo '== D3. After cleaning: compare with C5 from Step 2'
WITH daily AS (
    SELECT site, meter_key, read_date, SUM(litres) AS litres
    FROM clean_intervals
    WHERE read_date IS NOT NULL
    GROUP BY site, meter_key, read_date
)
SELECT site,
       COUNT(*)                                                         AS meter_days,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY litres)::numeric) AS median_litres_per_day,
       ROUND(AVG(litres))                                               AS mean_litres_per_day,
       ROUND(MIN(litres))                                               AS min_litres_per_day,
       ROUND(MAX(litres))                                               AS max_litres_per_day,
       COUNT(*) FILTER (WHERE litres < 0)                               AS negative_days
FROM daily GROUP BY site ORDER BY site;

\echo '== D4. Ten meters with the most quarantined intervals'
SELECT f.meter_key, m.cadence,
       COUNT(DISTINCT f.interval_id)                                     AS quarantined_intervals,
       STRING_AGG(DISTINCT f.flag_type, ', ' ORDER BY f.flag_type)       AS flag_types
FROM dq_flags f
JOIN dq_rules r USING (flag_type)
JOIN meters m USING (meter_key)
WHERE r.quarantined
GROUP BY f.meter_key, m.cadence
ORDER BY quarantined_intervals DESC
LIMIT 10;

\echo '== D5. Long periods of no flow (ZERO_RUN) by site'
WITH runs AS (
    SELECT site, meter_key, SUM(EXTRACT(EPOCH FROM end_ts - start_ts)) / 86400 AS zero_days
    FROM dq_flags WHERE flag_type = 'ZERO_RUN' GROUP BY site, meter_key
)
SELECT m.site,
       COUNT(*)                                              AS meters,
       COUNT(r.meter_key)                                    AS meters_with_zero_runs,
       ROUND(100.0 * COUNT(r.meter_key) / COUNT(*), 1)       AS pct_meters,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.zero_days)::numeric) AS median_zero_days_per_affected_meter
FROM meters m LEFT JOIN runs r USING (meter_key)
GROUP BY m.site ORDER BY m.site;
