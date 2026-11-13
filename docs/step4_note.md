# Step 4 note: reporting layer

Script: `sql/05_reporting.sql`. Output: schema `rpt`. Power BI connects to this schema only.

## Tables
| Table | Grain | Rows |
|---|---|---|
| dim_date | One row per day, Oct 2014 to Apr 2017 | 943 |
| dim_hour | One row per hour of the day | 24 |
| dim_property | One row per meter (property) | 769 |
| dim_dq_flag | One row per data quality rule | 7 |
| fact_hourly_consumption | Property x hour, hourly meters only | 5,403,828 |
| fact_daily_consumption | Property x day, all meters | 382,963 |
| fact_dq_flags | Property x day x flag type | 99,442 |

## Design decisions
- **Tables rather than views.** The hourly fact aggregates 5.6 million intervals. As a view that work would repeat on every Power BI refresh. The script builds the tables once and is re-run when the data changes. Every table and key column carries a `COMMENT`, which forms the data dictionary.
- **Quarantined hours have no row rather than zero.** Storing them as zero would make missing data look like no water used and would corrupt both averages and the continuous flow check.
- **Complete day.** A day counts as complete when 22 to 26 hours of clean data sit behind its total (the range allows for daylight saving days). Averages use complete days only, so a day with half its data quarantined does not pass as a low-use day.
- **Continuous flow.** A continuous flow day is a day with 23+ hours recorded where every hour used at least 1 litre (meters measure to the litre). Property status: Persistent = continuous flow on 50%+ of complete days (minimum 7 days); Intermittent = 10-50%; Not assessed = not an hourly meter or fewer than 30 complete days. This flags properties to investigate; it does not prove a leak.
- **Read completeness %.** The share of expected hours (hourly meters) or days (other meters) between first and last read that received at least one read.
- **Household features** are flattened to one row per property by taking the filled-in value across that meter's repeated rows.
- **Seasons** are meteorological: Winter Dec-Feb, Spring Mar-May, Summer Jun-Aug, Autumn Sep-Nov.

## Reconciliation (R2)
| Fact | Clean litres | Fact litres | Difference |
|---|---|---|---|
| Daily | 154,089,160 | 154,089,160 | 0 |
| Hourly | 111,029,132 | 111,029,132 | 0 |

The facts contain exactly the clean litres. Hourly is lower than daily because it covers hourly meters only and leaves out GAP_HOURLY intervals.

## First look at the five questions

**Q1 How much does each property use?** Average of each property's mean daily use (complete days, properties with 30+ days):

| Site | Properties | Average L/property/day | Median property |
|---|---|---|---|
| Tegna | 306 | 557 | 425 |
| Valencia | 419 | 340 | 207 |

Seasonal profile (L/property/day): Tegna winter 500, spring 581, summer 715, autumn 524 (summer is 43% above winter). Valencia winter 258, spring 259, summer 208, autumn 249 (summer is the lowest season, consistent with residents being away in August).

**Q2 When is demand highest?** Tegna peaks at 16:00 (33.8 L per property per hour against an average of 24.0; peak-to-average 1.41; quietest hour 00:00). Valencia peaks at 20:00 (15.3 against 9.2; peak-to-average 1.67; quietest hour 03:00).

**Q3 Which properties may have a leak?**

| Site | Persistent | Intermittent | None or rare | Not assessed |
|---|---|---|---|---|
| Tegna | 22 | 40 | 243 | 24 |
| Valencia | 6 | 13 | 124 | 297 |

Persistent properties average 1,035 L/day against 400 L/day for none or rare. Night use share (02:00-04:00): intermittent 9.6%, persistent 8.0%, none or rare 6.6%. A perfectly flat 24-hour flow would give 8.3%, so persistent properties sit close to a constant flow.

**Q4 How much do gardens, pools and irrigation add?** (indicative, small groups)

| Feature | With (properties) | Without (properties) |
|---|---|---|
| Garden | 537 L/day (22) | 263 L/day (154) |
| Pool | 759 L/day (11) | 278 L/day (165) |
| Irrigation | 815 L/day (6) | 287 L/day (170) |
| House vs flat | 391 L/day (28) | 277 L/day (144) |

**Q5 How far can the data be trusted?**

| Site | Cadence | Properties | Below 90% completeness | Avg completeness | Avg clean % |
|---|---|---|---|---|---|
| Tegna | Hourly | 321 | 155 | 86.1% | 88.1% |
| Tegna | Daily | 2 | 0 | 97.7% | 14.3% |
| Tegna | Irregular | 6 | 6 | 4.4% | 14.2% |
| Valencia | Hourly | 147 | 100 | 65.5% | 93.8% |
| Valencia | Daily | 215 | 49 | 88.7% | 89.3% |
| Valencia | Irregular | 78 | 38 | 74.1% | 79.9% |

Low completeness is mostly multi-day blocks of missing reads (for example TEG-219 has 7 outages of up to 4 days), not a calculation error.
