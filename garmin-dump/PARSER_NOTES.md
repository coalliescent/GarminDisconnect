# garmin-dump parser notes — Instinct 3 unknown FIT messages

Working doc for the reverse-engineering effort on the dominant `unknown_NNN`
FIT message types emitted by the Garmin Instinct 3. This file is now a
**status / reference doc**, not a planning doc — the v1 implementation has
landed (see `src/garmin_dump/ingest/sleep.py`,
`src/garmin_dump/ingest/monitoring.py`).

## Ground truth: confirmed message names

Two community sources cover almost everything we needed:

- **Gadgetbridge `FitDebug.java`** — case statements naming Garmin globals
  on the watch side.
  https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/fit/FitDebug.java
- **HarryOnline "Beyond the SDK" Google Sheet** — community-curated list of
  every undocumented mesg_num seen across Garmin's lineup.
  https://docs.google.com/spreadsheets/d/1x34eRAZ45nbi3U3GyANotgmoQfj0fR49wBxmL-oLogc/edit?usp=sharing

For sleep stage values, **Garmin's own FIT Java SDK** is the authoritative
source: `0=unmeasurable, 1=awake, 2=light, 3=deep, 4=rem, 255=invalid`.
https://github.com/garmin/fit-java-sdk/blob/main/src/main/java/com/garmin/fit/SleepLevel.java

| mesg_num | community name             | category | status (v1) |
| -------- | -------------------------- | -------- | ----------- |
| 211      | monitoring_hr_data         | monitor  | DECODED — emit `heart_rate` samples + rollup |
| 227      | stress_level               | monitor  | DECODED — emit `stress_level` + roll up `avg_stress` |
| 233      | *unknown to community*     | monitor + activity | DEFERRED — packed 4-byte bitfield, no timestamp |
| 273      | sleep_data_info            | sleep    | DECODED — used as session metadata anchor |
| 275      | sleep_level                | sleep    | DECODED — populates `sleep_stages` |
| 279      | *unknown to community*     | monitor  | DEFERRED — uint32 @ 2-min, range 2k–3k |
| 297      | respiration_rate           | monitor  | DECODED — emit `respiration_rate` (sint16/100) |
| 346      | sleep_assessment           | sleep    | PARTIAL — name known, field semantics unknown; stashed in raw_json |
| 370      | hrv_status_summary         | monitor  | not handled (sparse — present in 10 of 87 files) |
| 371      | hrv_value                  | monitor  | DECODED — emit `hrv_value_ms` |
| 382      | sleep_restless_moments     | sleep    | PARTIAL — 200-byte byte array stashed in raw_json |
| 412      | nap                        | sleep    | not handled (newer fw, present in 18 of 99 files) |
| 326      | gps_event                  | activity | not on critical path |
| 369      | training_readiness         | metrics  | not on critical path |
| 378      | training_load              | metrics  | not on critical path |

## What's still unknown

- **mesg_num 233** (60k records monitor + 119k activity, 4 raw bytes,
  no timestamp). Listed as `mesg_233?` by both Gadgetbridge and HarryOnline.
  The community has not cracked this one. To make progress: correlate
  per-minute byte patterns against the standard `monitoring` (g=55) records
  around the same minute, look for hidden timestamps in the 4 bytes, and/or
  correlate against simultaneous activity data.
- **mesg_num 279** (40k records monitor, uint32 @ 2-min, range 2001–2973).
  Smooth slow-moving signal. Needs side-by-side comparison with Garmin
  Connect to identify.
- **sleep_assessment field semantics**: we know the message name but not
  what each of its 17 fields represents. Best-candidate `sleep_score`
  (def_num 3) is provisional. All 17 fields are stashed verbatim in
  `sleep_sessions.raw_json["sleep_assessment"]` so the user can refine the
  mapping with a SQL update once they spot-check one night against Garmin
  Connect.
- **stress_level f2 / f4** (def_nums 2 and 4 on g=227): f2 is sint8 in range
  -97…+102 (148 distinct values, dense). f4 is sint8 with only 4 distinct
  values {1, 2, 125, 126} — likely a state/quality flag. f2 is stashed as
  `wellness_samples.metric='monitor_stress_f2'` for forensic recall.

## How v1 maps messages to viewer columns

| FIT msg / field         | parser → wellness_samples.metric | wellness_daily column           |
| ----------------------- | -------------------------------- | ------------------------------- |
| g=297.f0 (sint16/100)   | `respiration_rate`               | `respiration_avg`               |
| g=227.f0                | `stress_level`                   | `avg_stress`                    |
| g=227.f3 (sparse)       | `hrv_rmssd` (10..150 ms)         | (no column — sample only)       |
| g=227.f2 (forensic)     | `monitor_stress_f2`              | (none)                          |
| g=211.f0                | `heart_rate`                     | `min_hr` / `max_hr`             |
| g=371.f0                | `hrv_value_ms`                   | (none)                          |
| g=275.f0 (enum 0..4)    | (none — written to sleep_stages) | n/a                             |
| g=346.f3                | (none — written to sleep_score)  | n/a                             |

## Verification

After re-ingest, expected counts in `~/garmin-archive/garmin.db`:

```sql
SELECT COUNT(*) FROM sleep_sessions;                           -- ~99
SELECT COUNT(*) FROM sleep_stages;                             -- ~1700
SELECT stage, COUNT(*) FROM sleep_stages GROUP BY stage;       -- 4-5 rows
SELECT metric, COUNT(*) FROM wellness_samples GROUP BY metric; -- 8+ rows
SELECT COUNT(*) FROM wellness_daily WHERE avg_stress IS NOT NULL;
SELECT COUNT(*) FROM wellness_daily WHERE respiration_avg IS NOT NULL;
```

Then visually: `cd .. && make run`. Wellness tab should show stress and
respiration charts; Sleep tab should show the hypnogram with deep/light/rem/awake
bands and the regularity heatmap. **Spot-check one night against the watch
or Garmin Connect to confirm stage labels** — if wrong, edit `_STAGE_LABELS`
in `src/garmin_dump/ingest/sleep.py` and run `garmin-dump ingest --reparse`.
