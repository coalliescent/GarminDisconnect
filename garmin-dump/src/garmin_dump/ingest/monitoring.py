"""Monitoring (wellness) FIT file ingestion.

Monitoring files contain rolling 24-hour wellness telemetry: heart rate, steps, stress,
body battery, SpO2, respiration, calories, distance. Garmin uses several closely-related
message types and the field set varies between firmwares — we treat the file as a
stream of arbitrary `(timestamp, metric, value, unit)` samples (`wellness_samples`),
plus a single calendar-day rollup row (`wellness_daily`).

How the `monitoring` (g=55) message actually works
--------------------------------------------------

Everything below is checked against the FIT global profile that `fitdecode`
ships (`fitdecode.profile.MESSAGE_TYPES[55]`), not inferred from the data:

    f1  calories                  kcal          "Accumulated total calories.
                                                 Maintained ... for each activity_type"
    f2  distance                  m, scale 100  "Accumulated distance. ... for each
                                                 activity_type"
    f3  cycles                    scale 2       "Accumulated cycles. ... for each
                                                 activity_type"
          +-- subfield `steps`    scale 1       when activity_type in (walking, running)
          +-- subfield `strokes`  scale 2       when activity_type in (cycling, swimming)
    f5  activity_type
    f19 active_calories           kcal
    f24 current_activity_type_intensity -> expands to components (activity_type, intensity)
    f29 duration_min              min
    f31 ascent / f32 descent      m, scale 1000
    f33 moderate_activity_minutes / f34 vigorous_activity_minutes   minutes

Three consequences drive this module, each pinned by a test in
`tests/unit/test_monitoring_rollup.py` that decodes a real FIT blob:

1.  The counters ACCUMULATE PER activity_type, and the watch re-emits the
    running total on every flush — one wearer's `walking.active_calories`
    climbed 672 -> 704 -> 715 -> 777 inside a single file. So a day is the sum
    across activity types of the HIGH-WATER MARK within each, never a sum of
    the messages. Summing them invented steps: the 2026-09-11 file re-emitted
    the same day three times and reported 28,676 steps for a 14,338-step day.

2.  `steps` is a SUBFIELD of `cycles`, so f3 means different things per
    activity_type and only walking/running rows carry steps. Because
    `FieldData.is_named()` also matches the parent field, `get_value("cycles")`
    on a walking row returns the *steps* value (scale 1), while on a generic or
    cycling row it returns strides/strokes (scale 2) — the same raw f3 halved.
    Reading `cycles` as a step count therefore double-counts on one row shape
    and halves on another. We read the `steps` subfield and take `cycles * 2`
    only where activity_type says f3 is steps.

3.  There is NO `floors_climbed` field anywhere in the FIT profile. The old
    lookup could never fire, so that column has always been NULL; f31 `ascent`
    is the only plausible source and deriving floors from it is left to a
    follow-up rather than guessed at here.

Rollup formulas (the future viewer relies on these being stable):

    steps              = SUM over walking/running of MAX(steps, or cycles * 2)
    distance_m         = SUM over activity_type of MAX(distance)
    active_kcal        = SUM over activity_type of MAX(active_calories)
    bmr_kcal           = SUM over activity_type of MAX(calories) - active_kcal
    intensity_min      = MAX(moderate_activity_minutes) + 2 * MAX(vigorous)
    floors_climbed     = always NULL, see (3)
    resting_hr         = MIN of monitoring.heart_rate where activity_type == 'sedentary'
    min_hr / max_hr    = MIN/MAX of monitoring.heart_rate
    avg_stress         = AVG of monitoring.stress_level
    body_battery_min/max = MIN/MAX of monitoring.body_battery_level
    spo2_avg           = AVG of monitoring.spo2
    respiration_avg    = AVG of monitoring.respiration_rate

Intensity minutes take a max for the same reason as the rest: every windowed
message reports a total over [local midnight, its timestamp], so three
re-emissions of one day must not be added up. The one thing we cannot settle
from the profile is whether the device's counter resets daily or on Garmin's
weekly Intensity Minutes goal; if it is weekly, a day reads week-to-date. That
is a bounded, documented over-report rather than the unbounded triple-count the
old SUM produced.

Anything we can't compute stays NULL. Raw monitoring messages also land in
`wellness_samples` so an unrecognized field can be back-filled later.

`raw_json` is per-file, not per-day: it holds the messages of whichever file last
wrote the row, so it need not contain the messages the cumulative columns were
derived from.
"""

from __future__ import annotations

import sqlite3
from collections import defaultdict
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from garmin_dump.db.repo import json_dumps_safe, utc_now_iso
from garmin_dump.ingest.fit_reader import (
    field_def_num,
    field_units,
    iter_messages_for,
    iter_messages_for_num,
    message_to_dict,
    msg_num,
    raw_field_values,
    resolved_field_name,
    safe_get,
)

# We pull a generous set of message names: monitoring (the per-event sample), and
# monitoring_info (carries the local timestamp + activity_type list).
_MONITORING_NAMES = ("monitoring", "monitoring_info")

# Garmin Instinct 3 emits its real wellness telemetry through these undocumented
# global mesg nums (community names from Gadgetbridge / HarryOnline — see
# memory/reference_fit_decoding.md):
_RESPIRATION_RATE_MSG = 297     # f253 ts, f0 sint16 br/min×100, -200 = no signal
_STRESS_LEVEL_MSG = 227         # f1 ts, f0 sint16 stress, f3 sparse (HRV?), f2/f4 forensic
_MONITORING_HR_DATA_MSG = 211   # newer fw — actual HR samples
_HRV_VALUE_MSG = 371            # newer fw — per-night HRV samples
_NAMED_NUM_MSGS = (
    _RESPIRATION_RATE_MSG,
    _STRESS_LEVEL_MSG,
    _MONITORING_HR_DATA_MSG,
    _HRV_VALUE_MSG,
)

# Numeric fields that we extract as `wellness_samples` rows. Each becomes one
# (metric, value, unit) sample with the message's timestamp.
#
# `cycles` covers `steps`/`strokes` too: they are subfields of the same f3, and
# the extraction loop records whichever name fitdecode resolved. Listing both
# `cycles` and `steps` (as this did originally) wrote the identical value twice,
# so anything summing sample metrics counted a walking row's steps double.
#
# `floors_climbed` used to be listed here and is not a FIT field at all — see
# the module docstring. `ascent`/`descent` (f31/f32) are the real elevation
# signals and are captured so the floors follow-up has data to work from.
_SAMPLE_FIELDS = (
    "heart_rate",
    "stress_level",
    "body_battery_level",
    "spo2",
    "respiration_rate",
    "active_calories",
    "calories",
    "distance",
    "cycles",
    "ascent",
    "descent",
    "moderate_activity_minutes",
    "vigorous_activity_minutes",
)

SAMPLE_BATCH = 1000


def ingest_monitoring(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    path: Path,
) -> int:
    """Ingest a monitoring FIT file. Returns the number of sample rows inserted."""
    # First pass: read monitoring_info for the local TZ offset and base time. Anchor is
    # used to convert system_timestamp deltas into absolute UTC times.
    base_time: datetime | None = None
    local_offset_s: int | None = None
    for msg in iter_messages_for(path, ["monitoring_info"]):
        ts = safe_get(msg, "timestamp")
        if isinstance(ts, datetime):
            base_time = ts.astimezone(UTC) if ts.tzinfo else ts.replace(tzinfo=UTC)
        local_dt = safe_get(msg, "local_timestamp")
        if isinstance(local_dt, datetime) and base_time is not None:
            local_offset_s = int(
                (local_dt.replace(tzinfo=UTC) - base_time).total_seconds()
            )
        break  # one is enough

    # Second pass: stream the actual samples and accumulate the rollup.
    rollup = _RollupAccumulator(local_offset_s=local_offset_s)
    pending: list[tuple[Any, ...]] = []
    sample_count = 0
    seen_units: dict[str, str | None] = {}

    for msg in iter_messages_for(path, ["monitoring"]):
        msg_ts = _coerce_ts(safe_get(msg, "timestamp"), base_time)
        if msg_ts is None:
            continue
        rollup.add(msg, msg_ts)
        emitted: set[int] = set()
        for field_name in _SAMPLE_FIELDS:
            v = safe_get(msg, field_name)
            if v is None:
                continue
            # One physical field can answer to several profile names (f3 is
            # `cycles`/`steps`/`strokes`), so key on the definition number and
            # record the value once, under the name fitdecode resolved.
            def_num = field_def_num(msg, field_name)
            if def_num is not None:
                if def_num in emitted:
                    continue
                emitted.add(def_num)
            metric = resolved_field_name(msg, field_name) or field_name
            try:
                value = float(v)
            except (TypeError, ValueError):
                continue
            if metric not in seen_units:
                seen_units[metric] = field_units(msg, field_name)
            pending.append(
                (
                    device_id,
                    sync_id,
                    msg_ts.isoformat(),
                    metric,
                    value,
                    seen_units[metric],
                )
            )
            sample_count += 1
            if len(pending) >= SAMPLE_BATCH:
                _flush_samples(conn, pending, local_offset_s=local_offset_s)
                pending = []

    # Third pass: stream the Instinct 3's named-by-num messages (stress,
    # respiration, HR, HRV) and emit per-minute samples + feed the rollup.
    #
    # Naming nuance: fitdecode 0.11+ already decodes some of these messages
    # by name (`stress_level`, `respiration_rate`) and applies their published
    # scale factor — so `respiration_rate.f0` arrives as a float in br/min
    # rather than the raw sint16. We dispatch on integer global mesg num so
    # the code works whether fitdecode names the message or not, and we
    # accept either int (raw) or float (already-scaled) values.
    for msg in iter_messages_for_num(path, _NAMED_NUM_MSGS):
        n = msg_num(msg)
        raw = raw_field_values(msg)
        if n == _RESPIRATION_RATE_MSG:
            ts = _coerce_ts(raw.get(253), base_time)
            v = raw.get(0)
            value = _resp_to_brpm(v)
            if ts is None or value is None:
                continue
            pending.append(
                (
                    device_id,
                    sync_id,
                    ts.isoformat(),
                    "respiration_rate",
                    value,
                    "breaths/min",
                )
            )
            rollup.add_value(ts, "respiration_values", value)
            sample_count += 1
        elif n == _STRESS_LEVEL_MSG:
            ts = _coerce_ts(raw.get(1), base_time)  # NB: f1, not 253
            if ts is None:
                continue
            stress = raw.get(0)
            if isinstance(stress, int) and 0 <= stress <= 100:
                pending.append(
                    (
                        device_id,
                        sync_id,
                        ts.isoformat(),
                        "stress_level",
                        float(stress),
                        None,
                    )
                )
                rollup.add_value(ts, "stress_values", stress)
                sample_count += 1
            # f3 sint8, sparse 18..82 — plausibly HRV RMSSD ms. Emit only when
            # in plausible range; rollup goes through hrv_values.
            f3 = raw.get(3)
            if isinstance(f3, int) and 10 <= f3 <= 150:
                pending.append(
                    (
                        device_id,
                        sync_id,
                        ts.isoformat(),
                        "hrv_rmssd",
                        float(f3),
                        "ms",
                    )
                )
                rollup.add_value(ts, "hrv_values", f3)
                sample_count += 1
            # f2 sint8 -97..+102 — uncertain. Stash for forensic recall.
            f2 = raw.get(2)
            if isinstance(f2, int) and -100 < f2 < 110:
                pending.append(
                    (
                        device_id,
                        sync_id,
                        ts.isoformat(),
                        "monitor_stress_f2",
                        float(f2),
                        None,
                    )
                )
                sample_count += 1
        elif n == _MONITORING_HR_DATA_MSG:
            ts = _coerce_ts(raw.get(253), base_time)
            hr = raw.get(0)
            if ts is None or not isinstance(hr, int) or not (30 <= hr <= 220):
                continue
            pending.append(
                (
                    device_id,
                    sync_id,
                    ts.isoformat(),
                    "heart_rate",
                    float(hr),
                    "bpm",
                )
            )
            rollup.add_value(ts, "hr_values", hr)
            sample_count += 1
        elif n == _HRV_VALUE_MSG:
            ts = _coerce_ts(raw.get(253), base_time)
            v = raw.get(0)
            if ts is None or not isinstance(v, int) or not (5 <= v <= 200):
                continue
            pending.append(
                (
                    device_id,
                    sync_id,
                    ts.isoformat(),
                    "hrv_value_ms",
                    float(v),
                    "ms",
                )
            )
            rollup.add_value(ts, "hrv_values", v)
            sample_count += 1

        if len(pending) >= SAMPLE_BATCH:
            _flush_samples(conn, pending, local_offset_s=local_offset_s)
            pending = []

    if pending:
        _flush_samples(conn, pending, local_offset_s=local_offset_s)

    rollup.write(conn, sync_id=sync_id, device_id=device_id)
    return sample_count


def _flush_samples(
    conn: sqlite3.Connection,
    batch: list[tuple[Any, ...]],
    *,
    local_offset_s: int | None,
) -> None:
    """Insert a batch of (device_id, sync_id, ts, metric, value, unit)
    tuples, appending the file-wide `local_offset_s` to each row so the
    viewer can render hour-of-day in the wearer's local zone.
    """
    rows_with_offset = [(*row, local_offset_s) for row in batch]
    conn.executemany(
        """
        INSERT INTO wellness_samples (
            device_id, sync_id, timestamp_utc, metric, value, unit, local_offset_s
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        rows_with_offset,
    )


_FIT_EPOCH = datetime(1989, 12, 31, tzinfo=UTC)


def _coerce_ts(v: Any, base: datetime | None) -> datetime | None:
    """Coerce a fitdecode field value into a UTC datetime.

    Accepts three forms:
        - `datetime`: returned as-is (forced to UTC).
        - `int > 6e8`: FIT-epoch seconds since 1989-12-31, used by every
          named-by-num message we care about (stress_level.f1,
          respiration_rate.f253, monitoring_hr_data.f253, etc.). We use the
          numeric range to disambiguate — relative offsets are far smaller.
        - `int <= 6e8`: a small relative offset from `base`, used by the
          standard `monitoring` (g=55) message's compressed timestamps.
    """
    if isinstance(v, datetime):
        return v.astimezone(UTC) if v.tzinfo else v.replace(tzinfo=UTC)
    if isinstance(v, int):
        if v > 600_000_000:
            return _FIT_EPOCH + timedelta(seconds=v)
        if base is not None:
            return base + timedelta(seconds=v)
    return None


def _resp_to_brpm(v: Any) -> float | None:
    """Normalize a respiration_rate.f0 value to breaths/min.

    fitdecode 0.11+ decodes the message and applies Garmin's scale=100, so it
    hands us a float (e.g. -2.0 for the no-signal sentinel, 14.56 for a real
    sample). Older fitdecode versions surface the raw sint16 — values like
    -200 or 1456. Either way, anything ≤ 0 is the no-signal sentinel and
    anything > 50 br/min on the float path or > 5000 on the int path is
    bogus. Return None for both.
    """
    if isinstance(v, float):
        if v <= 0 or v > 50:
            return None
        return v
    if isinstance(v, int):
        if v <= 0 or v > 5000:
            return None
        return v / 100.0
    return None


# ---- daily rollup ----------------------------------------------------------------------


# Fields that accumulate per activity_type on `monitoring`: (fit field, rollup
# key, coercer). See the module docstring for why these take a max and never a
# sum. `steps` is handled separately because f3 is activity_type-dependent.
_CUMULATIVE_FIELDS: tuple[tuple[str, str, type[int] | type[float]], ...] = (
    ("distance", "distance_m", float),
    ("active_calories", "active_kcal", int),
    ("calories", "calories_total", int),
    ("moderate_activity_minutes", "moderate_min", int),
    ("vigorous_activity_minutes", "vigorous_min", int),
)
_CUMULATIVE_KEYS = ("steps", *(key for _, key, _ in _CUMULATIVE_FIELDS))

# f3 (`cycles`) only means *steps* when activity_type says so; for cycling and
# swimming the same field is strokes, and for generic/sedentary it is an
# undifferentiated cycle count. Anything outside this set is not a step source.
_STEP_ACTIVITY_TYPES = frozenset({"walking", "running"})

# `all` (enum 254) is an explicit cross-type aggregate, so adding it to the
# per-type totals would double the day. We have never seen the Instinct 3 emit
# it; excluding it costs nothing and removes the failure mode.
_AGGREGATE_ACTIVITY_TYPES = frozenset({"all"})


def _msg_steps(msg: Any, activity_type: str) -> int | None:
    """Step count carried by one `monitoring` message, or None.

    f3 is `cycles` with scale 2, and `steps` is its scale-1 subfield for
    walking/running. Two message shapes reach us:

      * `activity_type` present as f5 — fitdecode resolves the subfield, so
        `get_value("steps")` is the step count directly. (`get_value("cycles")`
        returns the *same* number here, because `is_named` matches the parent
        field; that equality is what made reading `cycles` look correct.)
      * `activity_type` arriving as an expanded component of f24, as the
        intraday messages do — fitdecode cannot resolve a subfield from an
        expanded field, so only `cycles` exists and it is the scale-2 value,
        i.e. half the steps.

    So: take `steps` when present, otherwise `cycles * 2`, and only where
    activity_type says f3 counts steps at all.
    """
    if activity_type not in _STEP_ACTIVITY_TYPES:
        return None
    if (steps := _coerce_number(safe_get(msg, "steps"), int)) is not None:
        return int(steps)
    if (cycles := _coerce_number(safe_get(msg, "cycles"), float)) is not None:
        return round(cycles * 2)
    return None


class _RollupAccumulator:
    """Accumulates per-day wellness metrics during a single-pass scan of monitoring."""

    def __init__(self, *, local_offset_s: int | None) -> None:
        self.offset = timedelta(seconds=local_offset_s or 0)
        self._by_date: dict[str, dict[str, Any]] = defaultdict(self._new_day)
        self._raw_msgs: dict[str, list[dict[str, Any]]] = defaultdict(list)

    def _new_day(self) -> dict[str, Any]:
        return {
            # key -> {activity_type: high-water mark}, see _CUMULATIVE_FIELDS.
            "cumulative": {key: {} for key in _CUMULATIVE_KEYS},
            "hr_values": [],
            "resting_hr_candidates": [],
            "stress_values": [],
            "body_battery_values": [],
            "spo2_values": [],
            "respiration_values": [],
            "hrv_values": [],
        }

    @staticmethod
    def _mark(
        d: dict[str, Any], key: str, activity_type: str, value: float | int | None
    ) -> None:
        """Record `value` as this activity_type's high-water mark for `key`.

        Never decreases: the counters accumulate, so a smaller value is an
        earlier snapshot of the same day and carries no new information.
        """
        if value is None:
            return
        by_type = d["cumulative"][key]
        if value > by_type.get(activity_type, 0):
            by_type[activity_type] = value

    def add_value(self, ts: datetime, key: str, value: float | int) -> None:
        """Append a single sample to the named per-day list. Used by the
        named-by-num pass for messages that don't carry the rich activity_type
        context that the standard `monitoring` (g=55) message has.
        """
        local_date = (ts + self.offset).date().isoformat()
        d = self._by_date[local_date]
        bucket = d.get(key)
        if isinstance(bucket, list):
            bucket.append(value)

    def _local_date(self, msg: Any, ts: datetime) -> str:
        """Local calendar day a monitoring message's data belongs to.

        A message carrying `duration_min` describes the window that ENDS at its
        timestamp rather than the instant it lands. Every one of the 276
        windowed messages across the 299 archived monitor files starts its
        window at local midnight, so the window is [midnight, midnight +
        duration_min] and the end-of-day snapshot is stamped exactly when the
        next local midnight strikes, with `duration_min: 1440`, reporting the
        day that just finished. Bucketing that by its own timestamp shifts every
        daily total forward by a day.

        Attributing by the window's MIDPOINT is exact for this shape: with the
        window anchored at midnight, the midpoint is `midnight + duration/2`,
        which lands inside the correct day for every duration up to 1440. Using
        the window's start would be exact too in principle, but 15 of those
        messages start within two minutes of midnight, where a little watch
        drift puts the start on the wrong side of it; the midpoint has half a
        day of margin either way.

        Everything else — including the timestampless intraday messages, which
        carry activity_type packed into f24 and which the viewer doesn't use
        yet — keeps its own day.
        """
        duration_min = _safe_int(safe_get(msg, "duration_min"))
        if duration_min is not None and duration_min > 0:
            ts = ts - timedelta(minutes=duration_min / 2)
        return (ts + self.offset).date().isoformat()

    def add(self, msg: Any, ts: datetime) -> None:
        local_date = self._local_date(msg, ts)
        d = self._by_date[local_date]
        self._raw_msgs[local_date].append(message_to_dict(msg))

        # A message with no activity_type at all still has its own accumulator;
        # `generic` is the profile's name for enum 0, so it is the natural key.
        raw_activity_type = safe_get(msg, "activity_type")
        activity_type = str(raw_activity_type or "generic").lower()
        if activity_type not in _AGGREGATE_ACTIVITY_TYPES:
            self._mark(d, "steps", activity_type, _msg_steps(msg, activity_type))
            for field, key, coercer in _CUMULATIVE_FIELDS:
                self._mark(
                    d, key, activity_type, _coerce_number(safe_get(msg, field), coercer)
                )
        if (hr := _safe_int(safe_get(msg, "heart_rate"))) is not None:
            d["hr_values"].append(hr)
            # Unchanged from before the cumulative rework: an explicitly
            # `generic` row is not a resting-HR candidate, but a row with no
            # activity_type field is.
            if activity_type in ("sedentary", "still") or raw_activity_type is None:
                d["resting_hr_candidates"].append(hr)
        if (s := _safe_int(safe_get(msg, "stress_level"))) is not None:
            d["stress_values"].append(s)
        if (bb := _safe_int(safe_get(msg, "body_battery_level"))) is not None:
            d["body_battery_values"].append(bb)
        if (sp := _safe_int(safe_get(msg, "spo2"))) is not None:
            d["spo2_values"].append(sp)
        if (r := _safe_float(safe_get(msg, "respiration_rate"))) is not None:
            d["respiration_values"].append(r)

    def write(self, conn: sqlite3.Connection, *, sync_id: int, device_id: int) -> None:
        now = utc_now_iso()
        for date_local, d in self._by_date.items():
            # One day = sum across activity types of each type's high-water mark.
            totals = {key: sum(by_type.values()) for key, by_type in d["cumulative"].items()}
            bmr_kcal = max(0, totals["calories_total"] - totals["active_kcal"]) or None
            intensity_min = totals["moderate_min"] + 2 * totals["vigorous_min"]
            # `floors_climbed` has no FIT field to read (see the module
            # docstring); it stays NULL until f31 `ascent` is promoted, and the
            # column keeps its merge clause below so that lands without a
            # schema change.
            floors_climbed = None
            # Resting HR: prefer the standard `monitoring`-message
            # `activity_type='sedentary'` candidates, but on Instinct 3 those
            # rarely materialize because almost all HR data lives in
            # `monitoring_hr_data` (g=211) and `hrv_value` (g=371) which don't
            # carry an activity_type. Fall back to the lowest 10th-percentile
            # of all hr_values for the day so we surface *something* usable
            # for the resting HR card / chart.
            resting_hr = _safe_min(d["resting_hr_candidates"]) or _percentile_low(d["hr_values"])
            conn.execute(
                """
                INSERT INTO wellness_daily (
                    device_id, sync_id, date_local,
                    steps, distance_m, active_kcal, bmr_kcal, floors_climbed, intensity_min,
                    resting_hr, min_hr, max_hr, avg_stress,
                    body_battery_min, body_battery_max,
                    spo2_avg, respiration_avg, raw_json, parsed_at_utc
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id, date_local) DO UPDATE SET
                    sync_id          = excluded.sync_id,
                    -- Accumulating family: a monitoring file is a rolling window
                    -- that overlaps its neighbours, so one local day is written
                    -- by several files in whatever order the pull happens to
                    -- process them. Take the high-water mark so a later, more
                    -- partial file can never move a finished day backwards --
                    -- and keep NULL as NULL, which the viewer depends on.
                    --
                    -- The merge is monotonic by design, which means it cannot
                    -- lower a value an older, buggier parser wrote: replaying
                    -- the correct number over a corrupt one leaves the corrupt
                    -- one. Repairing history therefore has to clear these
                    -- columns and rebuild, which is what
                    -- `db.migrations.clear_accumulated_wellness` is for --
                    -- called once by migration v3 and again by
                    -- `garmin-dump ingest --reparse`.
                    steps            = CASE WHEN excluded.steps IS NULL
                                            THEN wellness_daily.steps
                                            ELSE MAX(COALESCE(wellness_daily.steps, 0), excluded.steps) END,
                    distance_m       = CASE WHEN excluded.distance_m IS NULL
                                            THEN wellness_daily.distance_m
                                            ELSE MAX(COALESCE(wellness_daily.distance_m, 0.0), excluded.distance_m) END,
                    active_kcal      = CASE WHEN excluded.active_kcal IS NULL
                                            THEN wellness_daily.active_kcal
                                            ELSE MAX(COALESCE(wellness_daily.active_kcal, 0), excluded.active_kcal) END,
                    bmr_kcal         = CASE WHEN excluded.bmr_kcal IS NULL
                                            THEN wellness_daily.bmr_kcal
                                            ELSE MAX(COALESCE(wellness_daily.bmr_kcal, 0), excluded.bmr_kcal) END,
                    floors_climbed   = CASE WHEN excluded.floors_climbed IS NULL
                                            THEN wellness_daily.floors_climbed
                                            ELSE MAX(COALESCE(wellness_daily.floors_climbed, 0), excluded.floors_climbed) END,
                    -- Intensity minutes accumulate like the rest, so they merge
                    -- the same way rather than letting the last file win.
                    intensity_min    = CASE WHEN excluded.intensity_min IS NULL
                                            THEN wellness_daily.intensity_min
                                            ELSE MAX(COALESCE(wellness_daily.intensity_min, 0), excluded.intensity_min) END,
                    resting_hr       = excluded.resting_hr,
                    min_hr           = excluded.min_hr,
                    max_hr           = excluded.max_hr,
                    avg_stress       = excluded.avg_stress,
                    body_battery_min = excluded.body_battery_min,
                    body_battery_max = excluded.body_battery_max,
                    spo2_avg         = excluded.spo2_avg,
                    respiration_avg  = excluded.respiration_avg,
                    raw_json         = excluded.raw_json,
                    parsed_at_utc    = excluded.parsed_at_utc
                """,
                (
                    device_id,
                    sync_id,
                    date_local,
                    totals["steps"] or None,
                    totals["distance_m"] or None,
                    totals["active_kcal"] or None,
                    bmr_kcal,
                    floors_climbed,
                    intensity_min or None,
                    resting_hr,
                    _safe_min(d["hr_values"]),
                    _safe_max(d["hr_values"]),
                    _safe_avg_int(d["stress_values"]),
                    _safe_min(d["body_battery_values"]),
                    _safe_max(d["body_battery_values"]),
                    _safe_avg_int(d["spo2_values"]),
                    _safe_avg_float(d["respiration_values"]),
                    json_dumps_safe(self._raw_msgs[date_local]),
                    now,
                ),
            )


def _coerce_number(v: Any, coercer: type[int] | type[float]) -> int | float | None:
    """Coerce a raw FIT field value to `coercer`, or None if it isn't a number.

    `bool` is rejected rather than silently becoming 0/1: FIT enums decode to
    named strings, so a bool here means something upstream went wrong and a
    0 would quietly take part in a max.
    """
    if v is None or isinstance(v, bool):
        return None
    try:
        return coercer(v)
    except (TypeError, ValueError):
        return None


def _safe_int(v: Any) -> int | None:
    value = _coerce_number(v, int)
    return int(value) if value is not None else None


def _safe_float(v: Any) -> float | None:
    value = _coerce_number(v, float)
    return float(value) if value is not None else None


def _safe_min(xs: Iterable[int]) -> int | None:
    xs = list(xs)
    return min(xs) if xs else None


def _percentile_low(xs: Iterable[int]) -> int | None:
    """Approximate "resting HR" as the 10th-percentile of an HR sample list.

    Picking the absolute min is too sensitive to a single bad reading; the
    10th percentile filters out a few outliers without smearing into the
    bulk of the day's HR. With the user's typical 1-30 samples per day this
    just degrades to ~min for short lists, which is acceptable.
    """
    xs = sorted(int(x) for x in xs)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    idx = max(0, int(round(0.10 * (len(xs) - 1))))
    return xs[idx]


def _safe_max(xs: Iterable[int]) -> int | None:
    xs = list(xs)
    return max(xs) if xs else None


def _safe_avg_int(xs: Iterable[int]) -> int | None:
    xs = list(xs)
    return int(round(sum(xs) / len(xs))) if xs else None


def _safe_avg_float(xs: Iterable[float]) -> float | None:
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None
