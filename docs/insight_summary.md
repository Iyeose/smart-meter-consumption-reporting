# Smart meter consumption: insight summary

**Scope:** 769 household water smart meters in Tegna (Switzerland, 329 meters) and Valencia (Spain, 440 meters), October 2014 to April 2017. 6.3 million cumulative reads were turned into consumption, checked against seven data quality rules and reconciled in Excel to the litre. Consumption figures use the 689 properties with at least 30 complete days and at least 50% clean data.

## Three findings

**1. Use per property differs sharply by place and season.**
A Tegna property uses 554 litres a day on average (median 459), against 290 in Valencia (median 207): nearly twice as much, consistent with Tegna's single-family houses and Valencia's flats. The two sites also move in opposite directions in summer. Tegna rises 49% from winter to summer, which points to outdoor use. Valencia falls 32%, most likely because residents are away in August. One "summer uplift" figure for both sites (13%) would hide both stories.

**2. 28 properties show persistent continuous flow, and they use over three times as much water.**
On at least half of their assessed days, these properties used water in every single hour, including overnight. Their median use is 942 litres a day, against 281 for properties with little or no continuous flow (3.4x). Overnight they never drop much below about 20 litres an hour, while typical homes fall close to zero. At the top of the list, TEG-311, TEG-41 and TEG-45 showed continuous flow on 99.7% of days. A further 53 properties show it intermittently. As a rough indication only, if the 28 persistent properties used the same as a typical home, about 18,500 litres a day (around 6.8 million litres a year) would be saved.

**3. The data is usable, but the timing in one site cannot be trusted and many meters have gaps.**
90% of intervals passed every quality rule, and all 769 meters reconcile: the water each meter recorded equals clean plus quarantined litres. However, 348 meters (45%) received reads for less than 90% of the expected hours or days, mostly because of multi-day communication outages. Tegna's hourly pattern (quietest at midnight, busy at 03:00-05:00) indicates its timestamps are not in local time, so Tegna is excluded from time-of-day analysis. Valencia's demand peaks at 20:00 at 1.7 times the average hour, and on weekends the morning peak moves from 07:00 to 10:00-11:00.

## Three recommendations

**1. Investigate the 28 persistent-flow properties first, starting with those flowing on 90%+ of days.**
Use the ranked list on the Continuous flow page. A visit or customer contact can separate genuine leaks (supply pipe, running toilet) from legitimate constant use. The flag is a prompt to investigate, not proof of a leak, so track how many visits confirm a leak and use that to tune the 50% threshold.

**2. Time water-efficiency messages to each area's peak season, and aim them at outdoor use.**
Target house, garden and irrigation households before June, where summer demand climbs. Gardens (367 vs 216 L/day median), pools (348 vs 226) and irrigation (634 vs 222) all point the same way, but the groups are 5 to 26 properties, so treat these as a lead to test with a larger sample, not a measured effect. For demand planning, expect the opposite seasonal shape where many customers leave in summer.

**3. Fix the data foundations before scaling this up.**
Confirm the timestamp convention with the meter or data supplier before relying on hourly results. Investigate the communication outages behind the 348 low-completeness meters. Agree whether thresholds are tested on rounded or exact figures (the Excel check found 346 vs 348 meters below 90% because of rounding). Review the four Valencia meters that log reads seconds apart. The data quality page and `dq_flags` table give the meter-level list for each issue.
