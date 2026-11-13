# Profiling note (Step 1)

Source: SmartH2O anonymised datasets v1.0 (Zenodo record 556152), Tegna (CH) and Valencia (ES).
Run: `sql/01_load_raw.sql` then `sql/02_profile.sql` in PostgreSQL. Date profiled: 11 November 2026.

## What was loaded
| Site | Reads | Meters | First read | Last read |
|---|---|---|---|---|
| Tegna | 4,670,096 | 329 | 15 Oct 2014 20:00 | 9 Apr 2017 22:00 |
| Valencia | 1,619,155 | 440 | 18 Apr 2015 00:05 | 12 Apr 2017 11:08 |

Household file: 708 rows for 327 meters (Tegna) and 3,558 rows for 439 meters (Valencia). The file repeats each meter once per appliance combination, so it must be flattened to one row per property before use.

All row counts match the CSV line counts minus the header, so nothing was rejected on load.

## Reading interval
- Most common gap (P3): Tegna 1 hour (98.1% of gaps). Valencia 1 hour (81.7%), then 1 day (5.5%), then a long tail of gaps of 0 to 5 seconds.
- Meters by cadence, based on each meter's median gap (P4):

| Site | Hourly | Daily | Irregular |
|---|---|---|---|
| Tegna | 321 | 2 | 6 |
| Valencia | 147 | 215 | 78 |

- Reads per meter (P5): median 16,090 (Tegna) and 822 (Valencia). Only one meter covers less than 30 days.
- Decision: hourly analysis (demand profile, peak hour, night use, continuous flow) uses the 468 hourly meters. Daily and monthly analysis (consumption per property, seasonal trend) can use all meters with enough complete days.

## Units
- The README gives no unit. Typical use is 0.351 units per property per day in Tegna and 0.171 in Valencia (P7).
- As cubic metres that is 351 and 171 litres a day, which is in the normal range for household use (Valencia is mostly flats, Tegna mostly single-family houses). Readings are therefore treated as m³ and converted to litres (x 1000).

## Duplicates
- (P2) Tegna: 15 duplicated timestamps on 2 meters, 1 of them with conflicting values.
- Valencia: 24,538 duplicated timestamps (31,533 extra rows) on just 4 meters, 8,502 of them with conflicting values. The same 4 meters also log reads seconds apart, which explains the 0 to 5 second gaps in P3. These meters will be flagged in Step 3.

## Household features
- (P6) Only properties with both readings and filled-in features can be used for the water efficiency question:

| Site | Household meters | With readings | With features | Usable (both) | Flats | Houses | Gardens | Pools | Irrigation |
|---|---|---|---|---|---|---|---|---|---|
| Tegna | 327 | 281 | 17 | 17 | 2 | 14 | 15 | 1 | 1 |
| Valencia | 439 | 269 | 256 | 162 | 145 | 14 | 7 | 10 | 5 |

- What this means for the water efficiency question: 179 usable properties in total, with 22 gardens, 11 pools and 6 irrigation systems. These groups are too small for firm conclusions, so the water efficiency page will be presented as indicative, with the property count shown next to every figure. It is also the first page to cut if time runs short.

## Problems to handle in Step 3
- Negative steps (resets or replacements): 2,929 (Tegna), 27,837 (Valencia).
- Very large steps (over 5 m³ in one interval): 1,225 (Tegna), 22,677 (Valencia). The largest step is 51,224,090 m³ in Tegna and 1,034,729 m³ in Valencia, which are clearly meter faults rather than usage.
- Share of intervals with zero change: 50.8% (Tegna), 52.8% (Valencia). This is expected for hourly water data (nights, days out), so zero steps on their own are not an error. Only long unbroken runs of zeros will be flagged as possible stuck meters.

## Decisions taken
1. Meter key is site + meter id (e.g. TEG-34), because ids repeat across sites.
2. Readings are treated as m³ and reported in litres.
3. Hourly analysis uses hourly meters only. Daily analysis uses all meters.
4. Household features are taken per meter as the filled-in value across that meter's rows, because some repeated rows are blank.
5. The water efficiency analysis is labelled indicative because of the small feature sample.
6. Raw data is excluded from the GitHub repo (`.gitignore`) because of its size (Tegna file 198 MB) and licence terms.
