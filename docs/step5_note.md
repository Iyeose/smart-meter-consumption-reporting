# Step 5 note: Excel reconciliation

Workbook: `excel/reconciliation.xlsx`. Data: four CSVs exported by `sql/06_export_excel.sql` and loaded through Power Query, so **Data > Refresh All** picks up a new export.

## What the workbook proves
1. For every meter, the litres the meter itself recorded, (last reading - first reading) x 1000, equal clean litres + quarantined litres. This total is worked out without any of the SQL interval logic, so it is an independent check.
2. For every meter, clean litres equal the litres Power BI reads from `fact_daily_consumption`.

## Formulas used
- Lookups: `INDEX` / `MATCH` (works in every Excel version; XLOOKUP is not available in this version of Excel).
- Totals by status: `SUMIFS` on meter and status.
- Missing meters: `IFERROR(..., 0)` for the 7 meters with no clean complete days and so no row in the daily fact.
- Verdict: `IF(AND(ABS(check1)<1, ABS(check2)<1), "OK", "CHECK")`. The tolerance is there because Excel stores decimals in binary, so some differences come out as 0.00000001 instead of exactly 0.

## Results
| Check | Result |
|---|---|
| Meters reconciled | 769 |
| OK / CHECK | 769 / 0 |
| Clean litres, Excel | 154,089,160, matching SQL check R2 exactly |
| Clean litres, Tegna | 107,385,796, matching Step 3 D2 |
| Clean litres, Valencia | 46,703,364, matching Step 3 D2 |
| Meters below 90% read completeness | 346 in Excel against 348 in SQL (see below) |

## Data quality PivotTable
Flags by type and site, with Distinct Count of meters affected (via the Data Model). Totals match Step 3 D1, for example ZERO_RUN 458,470 (Tegna) and 86,638 (Valencia), NEGATIVE 2,929 and 19,465, SPIKE 1,264 and 14,768.

## Notes
- **The 346 vs 348 difference is a reconciliation finding, not an error.** SQL tests the exact completeness value; the export rounds it to one decimal. TEG-91 and TEG-92 sit between 89.95% and 90% and round to 90.0, so Excel does not count them. In production the fix is to agree that the threshold is tested on the rounded figure users see.
- The exception list is built with Power Query (reference query, filter below 90, sort ascending) rather than `FILTER`, so it refreshes with the data.
