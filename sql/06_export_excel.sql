/* =====================================================================
   06_export_excel.sql  -  Step 5: export the data for the Excel checks
   Create the folder C:\smart-meter-reporting\excel\data first, then:
       \i C:/smart-meter-reporting/sql/06_export_excel.sql
   Writes four small CSV files (all well under Excel's row limit).
   The heavy lifting stays in SQL; Excel independently re-adds the totals.
   ===================================================================== */
\set ON_ERROR_STOP on
\cd C:/smart-meter-reporting/excel/data

-- 1. meter_reads.csv: one row per meter, the first and last meter reading.
--    (last - first) x 1000 is the total litres the meter recorded,
--    worked out without using any of the interval calculations.
\copy (SELECT p.meter_key, p.site, p.cadence, e.first_reading_m3, e.last_reading_m3, p.read_completeness_pct, p.clean_interval_pct FROM rpt.dim_property p JOIN (SELECT DISTINCT meter_key, FIRST_VALUE(prev_reading_m3) OVER (PARTITION BY meter_key ORDER BY read_ts) AS first_reading_m3, FIRST_VALUE(reading_m3) OVER (PARTITION BY meter_key ORDER BY read_ts DESC) AS last_reading_m3 FROM reading_intervals) e USING (meter_key) ORDER BY p.meter_id) TO 'meter_reads.csv' WITH (FORMAT csv, HEADER true)

-- 2. interval_status.csv: litres per meter split into Clean and Quarantined
\copy (SELECT i.meter_key, CASE WHEN c.interval_id IS NULL THEN 'Quarantined' ELSE 'Clean' END AS status, COUNT(*) AS intervals, SUM(i.litres) AS litres FROM reading_intervals i LEFT JOIN clean_intervals c USING (interval_id) GROUP BY 1, 2 ORDER BY 1, 2) TO 'interval_status.csv' WITH (FORMAT csv, HEADER true)

-- 3. daily_fact_totals.csv: what Power BI will read, totalled per meter
\copy (SELECT p.meter_key, SUM(f.litres) AS fact_daily_litres, COUNT(*) AS days, COUNT(*) FILTER (WHERE f.is_complete_day) AS complete_days FROM rpt.fact_daily_consumption f JOIN rpt.dim_property p USING (meter_id) GROUP BY p.meter_key ORDER BY p.meter_key) TO 'daily_fact_totals.csv' WITH (FORMAT csv, HEADER true)

-- 4. dq_flags_by_meter.csv: flag counts per meter and type, for the PivotTable
\copy (SELECT f.meter_key, f.site, f.flag_type, r.sort_order, CASE WHEN r.quarantined THEN 'Yes' ELSE 'No' END AS quarantined, COUNT(*) AS flags FROM dq_flags f JOIN dq_rules r USING (flag_type) GROUP BY 1, 2, 3, 4, 5 ORDER BY 1, 4) TO 'dq_flags_by_meter.csv' WITH (FORMAT csv, HEADER true)

\echo 'Exported: meter_reads.csv, interval_status.csv, daily_fact_totals.csv, dq_flags_by_meter.csv'
