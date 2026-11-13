# Step 6 note: Power BI model, DAX and report design

File: `powerbi/smart_meter_report.pbix`. DAX source: `powerbi/measures.dax`. Theme: `powerbi/smart_meter_theme_light.json` (dark alternative: `smart_meter_theme_dark.json`).

## Model
Star schema built on the `rpt` schema in PostgreSQL (Import mode).

| Table | Role | Rows |
|---|---|---|
| DimProperty | Dimension: one row per meter/property | 769 |
| DimDate | Dimension: calendar, marked as date table | 943 |
| DimHour | Dimension: hour of day | 24 |
| DimDQFlag | Dimension: data quality rules | 7 |
| FactDaily | Fact: litres per property per day | 382,963 |
| FactHourly | Fact: litres per property per hour (hourly meters) | 5,403,828 |
| FactDQFlags | Fact: flag counts per property per day per type | 99,442 |

Nine one-to-many relationships, single cross-filter direction, dimension to fact. Key columns in the facts are hidden so report builders slice by the dimensions. Sort-by-column is set for month name, weekday name, season, hour label and flag type.

## Calculated columns
- `DimProperty[Complete Days]` = number of complete days per property. Uses context transition: `CALCULATE` turns the current row into a filter on FactDaily.
- `DimProperty[Is Reportable]` = at least 30 complete days AND at least 50% clean intervals. 689 of 769 properties qualify.
- `DimDate[day_type]` = "Weekday" or "Weekend" (added for the Patterns page).

### Why the Is Reportable rule exists
Averaging by household feature first gave irrigation homes 4,257 L/day. The cause was VAL-243, a faulty high-frequency meter with only 4% clean intervals whose remaining days averaged 22,749 L/day. With only 6 irrigation properties, one meter distorted every feature figure. The rule is set once as a column so every measure applies it identically.

## Measures and checked values
| Measure | Total | Tegna | Valencia |
|---|---|---|---|
| Total Litres | 154,089,160 | 107,385,796 | 46,703,364 |
| Avg Daily Litres per Property | 398 | 554 | 290 |
| Median Daily Litres per Property | 259 | 459 | 207 |
| Properties Reported | 689 | 281 | 408 |
| Summer Uplift % | 13.4% | +48.8% | -31.9% |
| Avg Litres per Property Hour | 20.55 | 23.96 | 9.19 |
| Peak Hour | 16:00 | 16:00 * | 20:00 |
| Peak to Average Ratio | 1.36 | 1.41 * | 1.67 |
| Night Use Share % | 7.5% | 8.3% * | 1.4% |
| Properties with Continuous Flow | 28 | 22 | 6 |
| Properties Flagged for Review | 81 | 62 | 19 |
| Read Completeness % | 81.1% | 84.7% | 78.4% |
| Properties Below 90% Completeness | 348 | 161 | 187 |
| Total DQ Flags | 680,019 | 518,560 | 161,459 |

Every value matches an independent SQL calculation. `Total Litres` also matches the Excel reconciliation.

\* Not reliable for Tegna; see below.

Note: one measure was renamed from "Avg Litres per Property-Hour" to "Avg Litres per Property Hour" because the DAX formula bar reads a hyphen in a measure name as a minus sign.

## Finding while building the report: Tegna timestamps
Tegna's hourly profile does not look like household use, even for properties without continuous flow: quietest at 00:00 (3.7 L/h), busy at 03:00-05:00 (19-27 L/h), peak at 16:00. Valencia's profile is normal (quietest 03:00, morning rise, evening peak at 20:00). The most likely cause is that Tegna timestamps are not in local time. The shape fits a shift of roughly 3-4 hours, but the daylight saving gaps found in Step 2 do not match a simple offset, so no correction was applied.

Decision: hour-of-day results (heatmap, hourly profile, peak hour, night share) use Valencia only, through visual-level filters, and the page says why. Daily, monthly, seasonal and continuous-flow results are not affected: the continuous-flow test checks that every hour used water, not which hour.

This also corrects an earlier reading: Tegna's 8.3% night share was first explained as continuous-flow properties flattening the profile. It is at least partly the timestamp issue.

## Report design
Five pages plus a hidden QA page. Each page title states its finding.

| Page | Title | Main visuals |
|---|---|---|
| Overview | Tegna homes use nearly twice as much water per day as Valencia's | KPI tiles, monthly trend by site, site slicer |
| Patterns | Valencia's demand peaks at 20:00, and weekend mornings start about three hours later | Valencia KPIs, hour x weekday heatmap, weekday vs weekend profile, seasonal comparison |
| Continuous flow | 28 properties draw water almost every hour of every day and use over 3x a typical home | Flag counts, ranked property table (click a row to filter), 24-hour profile by status, median use by status |
| Water efficiency | Homes with gardens, pools or irrigation use more water, but the samples are small | Indicative-only warning, four median comparisons with property counts in each title |
| Data quality | 90% of intervals passed every quality rule; 348 meters fall below 90% read completeness | DQ KPIs, flags by type and site, known issues panel, definitions table from DimDQFlag |
| QA check (hidden) | | Table of every measure by site, used to check DAX against SQL |

Styling is a custom JSON theme inspired by a reference dashboard: lavender page, white rounded cards with soft shadows, navy KPI tiles, navy table headers, blue/navy/teal palette. Overview is the landing page.
