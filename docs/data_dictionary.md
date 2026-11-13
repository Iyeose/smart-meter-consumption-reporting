# Data dictionary

Reporting layer: PostgreSQL schema `rpt`, built by `sql/05_reporting.sql` and loaded into Power BI. Power BI table names in brackets.

## `dim_property` (DimProperty)

One row per meter/property (769). Combines the meter, its household features, data quality scores and continuous flow status.

| Column | Type | Meaning |
|---|---|---|
| `meter_id` | integer | Surrogate key; joins to all fact tables |
| `meter_key` | text | Business key: site + original meter id (e.g. TEG-34), because ids repeat across sites |
| `site` | text | TEG or VAL |
| `site_name` | text | Tegna (CH) or Valencia (ES) |
| `cadence` | text | Typical reading interval from the meter's median gap: Hourly, Daily or Irregular |
| `first_read_date` | date | Date of the meter's first read |
| `last_read_date` | date | Date of the meter's last read |
| `has_household_features` | boolean | True when the household file records a property type for this meter |
| `property_type` | text | Flat, House (House or Single Family), Other, or Not recorded |
| `garden` | text | Garden, No garden or Not recorded |
| `pool` | text | Pool, No pool or Not recorded |
| `irrigation` | text | Irrigation, No irrigation or Not recorded |
| `household_size_m2` | numeric | Floor area in square metres, as supplied |
| `garden_area_m2` | numeric | Garden area in square metres, as supplied |
| `bathrooms` | numeric | Number of bathrooms, as supplied |
| `environmental_attitude` | text | Self-reported environmental sensitivity, as supplied |
| `read_completeness_pct` | numeric | Share of expected hours (hourly meters) or days (other meters) between first and last read that received at least one read |
| `clean_interval_pct` | numeric | Share of the meter's intervals that passed every quarantine rule |
| `below_90pct_completeness` | boolean | True when read completeness is under 90% (tested on the exact value) |
| `complete_hourly_days` | bigint | Days with 23+ clean hourly values |
| `continuous_flow_days` | bigint | Complete hourly days where every hour used at least 1 litre |
| `continuous_flow_pct` | numeric | continuous_flow_days as a % of complete_hourly_days |
| `continuous_flow_status` | text | Persistent (50%+ of days, min 7), Intermittent (10-50%), None or rare, or Not assessed (not an hourly meter or under 30 complete days). A prompt to investigate, not proof of a leak |
| `Complete Days` | calculated | Power BI calculated column: complete days in fact_daily_consumption |
| `Is Reportable` | calculated | Power BI calculated column: 30+ complete days and 50%+ clean intervals; only these properties feed consumption measures |

## `dim_date` (DimDate)

One row per calendar day, 1 Oct 2014 to 30 Apr 2017. Marked as the date table in Power BI.

| Column | Type | Meaning |
|---|---|---|
| `date_key` | integer | Date as a whole number (YYYYMMDD); joins to the fact tables |
| `date` | date | Calendar date |
| `year` | integer | Year |
| `month_num` | integer | Month number (1-12) |
| `month_name` | text | Short month name; sorted by month_num |
| `month_start` | date | First day of the month |
| `year_month` | text | Year and month as text (YYYY-MM); used on monthly trend axes |
| `weekday_num` | integer | ISO weekday (1 = Monday) |
| `weekday_name` | text | Short weekday name; sorted by weekday_num |
| `is_weekend` | boolean | True on Saturday and Sunday |
| `season` | text | Meteorological season: Winter Dec-Feb, Spring Mar-May, Summer Jun-Aug, Autumn Sep-Nov |
| `season_sort` | integer | Season order (1 = Winter) |
| `day_type` | calculated | Power BI calculated column: Weekday or Weekend |

## `dim_hour` (DimHour)

One row per hour of the day.

| Column | Type | Meaning |
|---|---|---|
| `hour` | integer | Hour (0-23); joins to fact_hourly_consumption |
| `hour_label` | text | Hour as text (00:00-23:00); sorted by hour |
| `day_period` | text | Night (00-06), Morning (06-12), Afternoon (12-18), Evening (18-24) |
| `is_night_window` | boolean | True for 02:00 and 03:00, the window used for night use share |

## `dim_dq_flag` (DimDQFlag)

One row per data quality rule (7). Feeds the definitions panel.

| Column | Type | Meaning |
|---|---|---|
| `flag_type` | text | Rule code (e.g. NEGATIVE) |
| `sort_order` | integer | Display order |
| `description` | text | What the rule detects, in plain English |
| `threshold` | text | The exact test applied |
| `action` | text | What happens to flagged data |
| `quarantined` | boolean | True when flagged intervals are excluded from clean_intervals |

## `fact_daily_consumption` (FactDaily)

Clean litres per property per day, all meters (382,963 rows).

| Column | Type | Meaning |
|---|---|---|
| `meter_id` | integer | Joins to dim_property |
| `date_key` | integer | Joins to dim_date |
| `litres` | numeric | Clean litres used that day (intervals placed by their midpoint) |
| `coverage_hours` | numeric | Hours of clean data behind the daily total |
| `is_complete_day` | boolean | True when coverage is 22-26 hours; averages use complete days only |
| `hours_recorded` | bigint | Clean hourly values that day (hourly meters only) |
| `min_hour_litres` | numeric | Lowest hourly value that day (hourly meters only) |
| `night_litres` | numeric | Litres used 02:00-04:00 (hourly meters only) |
| `is_continuous_flow_day` | boolean | True when 23+ hours are recorded and every hour used at least 1 litre |

## `fact_hourly_consumption` (FactHourly)

Clean litres per property per hour, hourly meters only (5,403,828 rows). Quarantined hours have no row; they are never stored as zero.

| Column | Type | Meaning |
|---|---|---|
| `meter_id` | integer | Joins to dim_property |
| `date_key` | integer | Joins to dim_date |
| `hour` | integer | Joins to dim_hour |
| `litres` | numeric | Clean litres used in the hour |

## `fact_dq_flags` (FactDQFlags)

Number of data quality flags per property per day per rule (99,442 rows).

| Column | Type | Meaning |
|---|---|---|
| `meter_id` | integer | Joins to dim_property |
| `date_key` | integer | Day the flagged interval started; joins to dim_date |
| `flag_type` | text | Joins to dim_dq_flag |
| `flag_count` | bigint | Number of flags |

## Working tables (public schema)

| Table | Built by | Contents |
|---|---|---|
| `raw_readings` | 01_load_raw.sql | Every read, typed: site, meter_key, read_ts, reading_m3 |
| `raw_households` | 01_load_raw.sql | Household file as supplied (text), one row per meter x appliance |
| `meters` | 02_profile.sql | One row per meter: reads, first/last read, median gap, cadence |
| `reading_intervals` | 03_consumption.sql | One row per pair of consecutive reads: delta_m3, litres, hour_start, read_date |
| `dq_rules` | 04_dq_flags.sql | The seven rules with thresholds and actions |
| `dq_flags` | 04_dq_flags.sql | One row per issue found, with reason |
| `clean_intervals` | 04_dq_flags.sql | reading_intervals minus quarantined rows |

## DAX measures

Source: `powerbi/measures.dax`. All consumption measures use reportable properties only.

| Measure | Definition |
|---|---|
| Total Litres | Sum of FactDaily[litres] |
| Avg Daily Litres per Property | For each reportable property, average litres on complete days; then the average across properties |
| Median Daily Litres per Property | As above, but the median property |
| Properties Reported | Number of reportable properties with at least one complete day in the current filter |
| Summer Uplift % | (Summer average - Winter average) / Winter average, using Avg Daily Litres per Property |
| Avg Litres per Property Hour | Average of FactHourly[litres] |
| Peak Hour | Hour with the highest Avg Litres per Property Hour across the 24-hour profile |
| Peak to Average Ratio | Highest hourly average divided by the average of the 24 hourly averages |
| Night Use Share % | Night litres (02:00-04:00) / all litres, on days with 23+ hours recorded |
| Properties with Continuous Flow | Count of properties with status Persistent |
| Properties Flagged for Review | Count of properties with status Persistent or Intermittent |
| Read Completeness % | Average of read_completeness_pct / 100 |
| Properties Below 90% Completeness | Count of properties with below_90pct_completeness = True |
| Total DQ Flags | Sum of FactDQFlags[flag_count] |
