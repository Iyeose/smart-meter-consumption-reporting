# Step 3 note: data quality flags

Script: `sql/04_dq_flags.sql`. Output tables: `dq_rules` (7 rules), `dq_flags` (680,019 rows), `clean_intervals` (5,661,430 rows).
Nothing is deleted. `reading_intervals` still holds every interval; quarantined rows are simply left out of `clean_intervals`.

## Rules and why each threshold was chosen
| Flag | Threshold | Why this threshold | Action |
|---|---|---|---|
| DUPLICATE_TS | Any repeated meter + timestamp | Two values for one moment cannot both be right | Last row in the file kept (done in Step 2), others recorded here |
| NEGATIVE | Change below 0 L | A cumulative meter cannot run backwards: reset, replacement, bad read or reverse flow. Drops under 10 L are labelled as jitter, larger ones as resets or bad reads | Quarantined |
| REBOUND | The interval straight after a drop, when the reading returns to at least its pre-drop level | Removing only the drop would leave the recovery counted as phantom usage. Common in Valencia: 9,268 of 19,465 drops recovered in the next read | Quarantined |
| SPIKE | Over 3,000 L per hour (intervals under 1 hour treated as 1 hour) | A household supply delivers roughly 1,500-1,800 L/h at most. The 99.9th percentile of real hourly use in Tegna is about 1,750 L, so 3,000 L/h catches impossible values without cutting genuine heavy use | Quarantined |
| GAP_LONG | Over 36 hours between reads | The water cannot be placed in a day | Quarantined |
| GAP_HOURLY | Hourly meter, gap of 90 minutes to 36 hours | Volume is real and can be placed in a day, but not in an hour | Kept in daily totals, left out of hourly tables |
| ZERO_RUN | 14 days or more of unbroken zero change | The data cannot tell a stuck meter from an empty property. Either way it should not pull down use per property | Quarantined, so averages describe properties in use |

The ZERO_RUN rule uses the gaps-and-islands technique: the difference between two `ROW_NUMBER()` sequences gives each unbroken run of zeros its own id, so each run's length can be summed.

## Flags found (D1)
| Flag | Tegna flags (meters) | Valencia flags (meters) |
|---|---|---|
| DUPLICATE_TS | 15 (2) | 24,538 (4) |
| NEGATIVE | 2,929 (181) | 19,465 (370) |
| REBOUND | 225 (127) | 9,268 (324) |
| SPIKE | 1,264 (98) | 14,768 (21) |
| GAP_LONG | 3,421 (329) | 5,241 (436) |
| GAP_HOURLY | 52,236 (321) | 1,541 (146) |
| ZERO_RUN | 458,470 (99) | 86,638 (105) |

The litres inside flagged intervals run into trillions (for example, -21.5 trillion litres in Tegna NEGATIVE intervals). These are meter faults, not water, which is why they are quarantined rather than corrected.

## Quarantine balance (D2)
| | Tegna | Valencia |
|---|---|---|
| All intervals | 4,669,752 | 1,587,182 |
| Clean | 4,203,946 (90.03%) | 1,457,484 (91.83%) |
| Quarantined | 465,806 | 129,698 |

All intervals = clean + quarantined at both sites, so nothing was lost.

## Before and after cleaning (Step 2 C5 vs Step 3 D3)
| | Tegna before | Tegna after | Valencia before | Valencia after |
|---|---|---|---|---|
| Meter-days | 212,407 | 191,862 | 203,556 | 191,101 |
| Median L/day | 302 | 352 | 182 | 192 |
| Mean L/day | -6,996,299 | 560 | 226 | 244 |
| Lowest day | -51.2 billion L | 0 | -99.6 million L | 0 |
| Highest day | 51.2 billion L | 66,463 | 99.3 million L | 60,752 |
| Negative days | 583 | 0 | 2,253 | 0 |

The median rose slightly after cleaning because ZERO_RUN removes long no-flow periods, so the figures describe properties in use.

## Worst meters (D4)
VAL-243 has the most quarantined intervals (29,356: GAP_LONG, NEGATIVE, REBOUND, SPIKE). It is one of the four high-frequency Valencia meters found in profiling, so that issue is traced to a specific meter. The rest of the top ten are Tegna hourly meters where ZERO_RUN dominates, mostly combined with long gaps.

## Long periods of no flow (D5)
- Tegna: 99 of 329 meters (30.1%) have runs of 14+ days with no flow; the median affected meter has 153 such days.
- Valencia: 105 of 440 meters (23.9%); median 56 days.
- Interpretation: long empty spells, especially in Tegna, look like seasonal or second homes. This is stated with care, because a stuck meter would look the same.

## What was deliberately not removed
After cleaning, the highest day is still about 66,000 litres. Meter TEG-352 runs at a steady ~2,750 L every hour around the clock, including 02:00-04:00. That is below the spike threshold and is not a reading fault: it is the continuous-flow pattern the leak question looks for. Around 50 Tegna meters have days over 10,000 L. These are kept, the continuous-flow flag in Step 4 is designed to surface them, and the report shows the median alongside the mean because a few very high users pull the mean up.
