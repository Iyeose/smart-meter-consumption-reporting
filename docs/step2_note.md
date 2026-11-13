# Step 2 note: from reads to consumption

Script: `sql/03_consumption.sql`. Output table: `reading_intervals` (6,256,934 rows).

## Method
- Consumption = this reading - previous reading for the same meter, using `LAG()` over `meter_key` ordered by `read_ts`.
- Readings are m³ (see profiling note), so litres = delta x 1000.
- Duplicate timestamps: the last row in the file was kept; 15 rows (Tegna) and 31,533 rows (Valencia) were removed before calculating. They are flagged in Step 3.
- Each interval is placed in an hour and a day by its midpoint (a 10:00 to 11:00 interval belongs to the 10:00 hour; a 00:05 to 00:05 daily interval belongs to that day).
- An interval is placed in an hour only if the gap is 90 minutes or less, and in a day only if the gap is 36 hours or less. Longer intervals are not spread out, because spreading invents a usage pattern and hides the night-time zeros the leak check depends on. Their litres stay in the table so totals still reconcile.

## Checks
| Check | Tegna | Valencia | Result |
|---|---|---|---|
| C1 reads - duplicates - first reads = intervals | 4,670,096 - 15 - 329 = 4,669,752 | 1,619,155 - 31,533 - 440 = 1,587,182 | Balances at both sites |
| C2 meters without consumption rows | 0 of 329 | 0 of 440 | Pass |
| C3 meters failing the telescoping check (sum of deltas = last - first reading) | 0 of 769 meters in total | | Pass: the LAG logic is correct for every meter |
| C4 hourly meters: intervals placed in an hour / a day | 98.8% / 99.9% | 99.8% / 99.9% | Strong base for hourly analysis |

Unallocated long gaps (C4): 3,314 intervals on Tegna hourly meters, 1,295 on Valencia hourly meters, 3,381 on Valencia daily meters. These become gap flags in Step 3.

## What the uncleaned numbers show (C5)
| | Tegna | Valencia |
|---|---|---|
| Meter-days | 212,407 | 203,556 |
| Median litres per property per day | 302 | 182 |
| Mean litres per property per day | -6,996,299 | 226 |
| Lowest day | -51,224,029,880 L | -99,563,100 L |
| Highest day | 51,223,978,490 L | 99,331,758 L |
| Days with negative use | 583 | 2,253 |

Why they differ: the median is sensible, but a small number of meter resets and faulty reads produce values in the billions of litres, which wipe out the mean. A report built on this data without cleaning would be meaningless. This is the case for Step 3.

## Known limitation: daylight saving
Timestamps are local clock time (C6). On 29 March 2015, 190 Tegna meters show a 2-hour gap at 04:00 (the clocks went forward). On 25 October 2015, 189 meters show a 3-hour gap at 02:00 (the repeated hour when the clocks went back is missing). These intervals are left out of the hourly tables, which loses about one hour per meter per daylight saving change. The litres are still counted in the daily figures, so totals are unaffected.
