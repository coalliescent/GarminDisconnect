"""Monitoring (wellness) FIT file ingestion.

Monitoring files contain rolling 24-hour wellness telemetry: heart rate, steps, stress,
body battery, SpO2, respiration, calories, distance. Garmin uses several closely-related
message types and the field set varies between firmwares — we treat the file as a
stream of arbitrary `(timestamp, metric, value, unit)` samples (`wellness_samples`),
plus a single calendar-day rollup row (`wellness_daily`).

Rollup formulas (documented here because the future viewer will rely on them being
stable):

    steps              = SUM of monitoring.cycles where activity_type == 'walking'/'running'
    distance_m         = SUM of monitoring.distance
    active_kcal        = SUM of monitoring.active_calories
    bmr_kcal           = SUM of monitoring.calories - active_kcal (best effort)
    floors_climbed     = SUM of monitoring.floors_climbed
    intensity_min      = SUM of monitoring.moderate_activity_minutes + 2 * vigorous
    resting_hr         = MIN of monitoring.heart_rate where activity_type == 'sedentary'
    min_hr / max_hr    = MIN/MAX of monitoring.heart_rate
    avg_stress         = AVG of monitoring.stress_level
    body_battery_min/max = MIN/MAX of monitoring.body_battery_level
    spo2_avg           = AVG of monitoring.spo2
    respiration_avg    = AVG of monitoring.respiration_rate

Anything we can't compute stays NULL. Raw monitoring messages also land in
`wellness_samples` so an unrecognized field can be back-filled later.
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
    field_units,
    iter_messages_for,
    iter_messages_for_num,
    message_to_dict,
    msg_num,
    raw_field_values,
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
    "steps",
    "floors_climbed",
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
        for field_name in _SAMPLE_FIELDS:
            v = safe_get(msg, field_name)
            if v is None:
                continue
            try:
                value = float(v)
            except (TypeError, ValueError):
                continue
            if field_name not in seen_units:
                seen_units[field_name] = field_units(msg, field_name)
            pending.append(
                (
                    device_id,
                    sync_id,
                    msg_ts.isoformat(),
                    field_name,
                    value,
                    seen_units[field_name],
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


class _RollupAccumulator:
    """Accumulates per-day wellness metrics during a single-pass scan of monitoring."""

    def __init__(self, *, local_offset_s: int | None) -> None:
        self.offset = timedelta(seconds=local_offset_s or 0)
        self._by_date: dict[str, dict[str, Any]] = defaultdict(self._new_day)
        self._raw_msgs: dict[str, list[dict[str, Any]]] = defaultdict(list)

    def _new_day(self) -> dict[str, Any]:
        return {
            "steps": 0,
            "distance_m": 0.0,
            "active_kcal": 0,
            "calories_total": 0,
            "floors_climbed": 0,
            "moderate_min": 0,
            "vigorous_min": 0,
            "hr_values": [],
            "resting_hr_candidates": [],
            "stress_values": [],
            "body_battery_values": [],
            "spo2_values": [],
            "respiration_values": [],
            "hrv_values": [],
        }

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

    def add(self, msg: Any, ts: datetime) -> None:
        local_date = (ts + self.offset).date().isoformat()
        d = self._by_date[local_date]
        self._raw_msgs[local_date].append(message_to_dict(msg))

        if (s := _safe_int(safe_get(msg, "cycles") or safe_get(msg, "steps"))) is not None:
            activity_type = safe_get(msg, "activity_type") or ""
            if str(activity_type).lower() in ("walking", "running"):
                d["steps"] += s
        if (dist := _safe_float(safe_get(msg, "distance"))) is not None:
            d["distance_m"] += dist
        if (cal := _safe_int(safe_get(msg, "active_calories"))) is not None:
            d["active_kcal"] += cal
        if (cal := _safe_int(safe_get(msg, "calories"))) is not None:
            d["calories_total"] += cal
        if (floors := _safe_int(safe_get(msg, "floors_climbed"))) is not None:
            d["floors_climbed"] += floors
        if (m := _safe_int(safe_get(msg, "moderate_activity_minutes"))) is not None:
            d["moderate_min"] += m
        if (v := _safe_int(safe_get(msg, "vigorous_activity_minutes"))) is not None:
            d["vigorous_min"] += v
        if (hr := _safe_int(safe_get(msg, "heart_rate"))) is not None:
            d["hr_values"].append(hr)
            activity_type = str(safe_get(msg, "activity_type") or "").lower()
            if activity_type in ("sedentary", "still", ""):
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
            bmr_kcal = max(0, d["calories_total"] - d["active_kcal"]) or None
            intensity_min = (d["moderate_min"] or 0) + 2 * (d["vigorous_min"] or 0)
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
                    steps            = excluded.steps,
                    distance_m       = excluded.distance_m,
                    active_kcal      = excluded.active_kcal,
                    bmr_kcal         = excluded.bmr_kcal,
                    floors_climbed   = excluded.floors_climbed,
                    intensity_min    = excluded.intensity_min,
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
                    d["steps"] or None,
                    d["distance_m"] or None,
                    d["active_kcal"] or None,
                    bmr_kcal,
                    d["floors_climbed"] or None,
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


def _safe_int(v: Any) -> int | None:
    if v is None:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _safe_float(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


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
