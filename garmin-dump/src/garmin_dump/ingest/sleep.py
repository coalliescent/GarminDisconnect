"""Sleep FIT file ingestion.

The Garmin Instinct 3 stores its sleep telemetry across four undocumented FIT
message types that fitdecode 0.10 does not recognize. We address them by
integer global mesg num via `MessageBuckets.by_num`. Names are confirmed
against Gadgetbridge's `FitDebug.java` and the HarryOnline "Beyond the SDK"
spreadsheet (see `memory/reference_fit_decoding.md`).

| mesg | name                    | per file | role                              |
| ---- | ----------------------- | -------- | --------------------------------- |
| 273  | sleep_data_info         | 1        | session metadata + firmware       |
| 275  | sleep_level             | many     | per-event stage timeline          |
| 346  | sleep_assessment        | 1        | 17-field score breakdown          |
| 382  | sleep_restless_moments  | 1        | 200-byte per-minute movement bins |

Stage enum values are confirmed by Garmin's official FIT Java SDK
`SleepLevel.java`: 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=rem.

Sleep_assessment field meanings are NOT published by Garmin or the
community. We pick the best-candidate field for `sleep_score` based on
value distribution across the user's archive (f3, range 50–100, avg 78) and
stash all 17 fields verbatim under `raw_json["sleep_assessment"]` so the
mapping can be refined with a SQL update later.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from typing import Any

from garmin_dump.db.repo import json_dumps_safe, utc_now_iso
from garmin_dump.ingest.fit_reader import (
    MessageBuckets,
    raw_field_values,
    safe_get,
)

# Global mesg nums (community-confirmed names).
_SLEEP_DATA_INFO_MSG = 273
_SLEEP_LEVEL_MSG = 275
_SLEEP_ASSESSMENT_MSG = 346
_SLEEP_RESTLESS_MOMENTS_MSG = 382

# Authoritative — Garmin FIT Java SDK SleepLevel.java.
_STAGE_LABELS: dict[int, str] = {
    0: "unmeasurable",
    1: "awake",
    2: "light",
    3: "deep",
    4: "rem",
}

# Field def_nums.
_F_TIMESTAMP = 253      # most messages
_F_STAGE = 0            # sleep_level.f0 — stage enum
_F_ASSESSMENT_SCORE = 3 # sleep_assessment.f3 — best candidate for overall score
_F_INFO_LOCAL_TS = 2    # sleep_data_info.f2 — local timestamp (FIT epoch but in local hour)

# sleep_assessment field 15 is uint16 (645–3283 in our archive); the rest are
# uint8/enum. Stored verbatim in raw_json so they can be relabeled later.

# Heuristic: when assigning a duration to the final stage transition (the one
# with no successor), cap at this many seconds so a stale row doesn't claim
# the rest of the file.
_FINAL_STAGE_MAX_S = 60 * 30


def ingest_sleep(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    buckets: MessageBuckets,
) -> int | None:
    """Ingest a sleep file's buckets. Returns sleep_id, or None if there's no
    usable session anchor."""
    file_id_msgs = buckets.get("file_id")
    if not file_id_msgs:
        return None

    info_msgs = buckets.get_num(_SLEEP_DATA_INFO_MSG)
    level_msgs = buckets.get_num(_SLEEP_LEVEL_MSG)
    assessment_msgs = buckets.get_num(_SLEEP_ASSESSMENT_MSG)
    restless_msgs = buckets.get_num(_SLEEP_RESTLESS_MOMENTS_MSG)

    # The canonical session window is bounded by the EARLIEST and LATEST
    # `sleep_level` timestamps — those are the actual stage transition events
    # during sleep. `file_id.time_created` is when the file was finalized
    # (typically *after* the sleep ended), so it's wrong as a start anchor.
    # Fall back to time_created only when there are no level messages at all,
    # so we still produce a row for empty placeholder files.
    start_dt, end_dt = _stage_time_window(level_msgs)
    if start_dt is None:
        start_dt = _as_dt(safe_get(file_id_msgs[0], "time_created"))
    if start_dt is None:
        return None
    if end_dt is None:
        end_dt = start_dt
    start_iso = start_dt.isoformat()
    end_iso = end_dt.isoformat()
    duration_s = int((end_dt - start_dt).total_seconds()) or None

    # Pick a sleep score from sleep_assessment.f3 (best-candidate, refine
    # later by spot-checking against Garmin Connect — see module docstring).
    sleep_score = None
    assessment_raw: dict[int, Any] = {}
    if assessment_msgs:
        assessment_raw = raw_field_values(assessment_msgs[0])
        candidate = assessment_raw.get(_F_ASSESSMENT_SCORE)
        if isinstance(candidate, int) and 0 <= candidate <= 100:
            sleep_score = candidate

    # Local TZ offset, derived from sleep_data_info: f253 is the UTC FIT-epoch
    # timestamp, f2 is the same instant expressed as if it were the wearer's
    # local clock (Garmin embeds local times this way for displays). Their
    # difference in seconds is the signed offset (negative for west-of-UTC,
    # so PDT = -25200). NULL if the file lacks sleep_data_info.
    local_offset_s: int | None = None
    info_raw: dict[int, Any] = {}
    if info_msgs:
        info_raw = raw_field_values(info_msgs[0])
        utc_ts = info_raw.get(_F_TIMESTAMP)
        local_ts = info_raw.get(_F_INFO_LOCAL_TS)
        if isinstance(utc_ts, int) and isinstance(local_ts, int):
            local_offset_s = local_ts - utc_ts

    # Per-stage durations from the sleep_level timeline.
    stage_rows, stage_totals = _build_stage_rows(level_msgs, end_dt)

    # Restless-moments raw payload (the 200-byte movement waveform).
    restless_raw: dict[int, Any] = {}
    if restless_msgs:
        restless_raw = raw_field_values(restless_msgs[0])

    raw_json = json_dumps_safe(
        {
            "sleep_data_info": info_raw or None,
            "sleep_assessment": assessment_raw or None,
            "restless_moments": restless_raw or None,
        }
    )

    conn.execute(
        """
        INSERT INTO sleep_sessions (
            device_id, sync_id, start_utc, end_utc, duration_s, sleep_score,
            deep_s, light_s, rem_s, awake_s,
            avg_hr, avg_respiration, avg_spo2, avg_stress,
            raw_json, parsed_at_utc, local_offset_s
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?)
        ON CONFLICT(device_id, start_utc) DO UPDATE SET
            sync_id        = excluded.sync_id,
            end_utc        = excluded.end_utc,
            duration_s     = excluded.duration_s,
            sleep_score    = excluded.sleep_score,
            deep_s         = excluded.deep_s,
            light_s        = excluded.light_s,
            rem_s          = excluded.rem_s,
            awake_s        = excluded.awake_s,
            raw_json       = excluded.raw_json,
            parsed_at_utc  = excluded.parsed_at_utc,
            local_offset_s = excluded.local_offset_s
        """,
        (
            device_id,
            sync_id,
            start_iso,
            end_iso,
            duration_s,
            sleep_score,
            stage_totals.get("deep") or None,
            stage_totals.get("light") or None,
            stage_totals.get("rem") or None,
            stage_totals.get("awake") or None,
            raw_json,
            utc_now_iso(),
            local_offset_s,
        ),
    )
    # Always look up sleep_id by (device_id, start_utc) — `cur.lastrowid` is
    # unreliable on the upsert path (sqlite returns 0 when ON CONFLICT fires).
    row = conn.execute(
        "SELECT sleep_id FROM sleep_sessions WHERE device_id = ? AND start_utc = ?",
        (device_id, start_iso),
    ).fetchone()
    sleep_id = int(row[0]) if row is not None else 0

    # Replace any prior sleep_stages for this session so reparses are idempotent.
    if sleep_id:
        conn.execute("DELETE FROM sleep_stages WHERE sleep_id = ?", (sleep_id,))
        if stage_rows:
            conn.executemany(
                """
                INSERT INTO sleep_stages (sleep_id, start_utc, end_utc, stage)
                VALUES (?, ?, ?, ?)
                """,
                [(sleep_id, s, e, label) for (s, e, label) in stage_rows],
            )

    return sleep_id or None


def _build_stage_rows(
    level_msgs: list[Any], end_dt: datetime
) -> tuple[list[tuple[str, str, str]], dict[str, int]]:
    """Walk the sleep_level timeline and return (stage_rows, per-stage seconds).

    Each row's end_utc comes from the *next* row's timestamp; the last row's
    end_utc is `end_dt` (capped at _FINAL_STAGE_MAX_S so a stale tail doesn't
    swallow the whole night).
    """
    rows: list[tuple[str, str, str]] = []
    totals: dict[str, int] = {"deep": 0, "light": 0, "rem": 0, "awake": 0}

    parsed: list[tuple[datetime, int]] = []
    for msg in level_msgs:
        raw = raw_field_values(msg)
        ts = _as_dt(raw.get(_F_TIMESTAMP))
        stage = raw.get(_F_STAGE)
        if ts is None or not isinstance(stage, int):
            continue
        parsed.append((ts, stage))
    parsed.sort(key=lambda p: p[0])

    for i, (ts, stage_int) in enumerate(parsed):
        if i + 1 < len(parsed):
            next_ts = parsed[i + 1][0]
        else:
            tail = (end_dt - ts).total_seconds()
            tail = max(0.0, min(float(_FINAL_STAGE_MAX_S), tail))
            next_ts = ts + timedelta(seconds=tail)
        duration = int((next_ts - ts).total_seconds())
        if duration < 0:
            duration = 0
        label = _STAGE_LABELS.get(stage_int, f"unknown_{stage_int}")
        rows.append((ts.isoformat(), next_ts.isoformat(), label))
        if label in totals:
            totals[label] += duration

    return rows, totals


def _stage_time_window(
    level_msgs: list[Any],
) -> tuple[datetime | None, datetime | None]:
    """Return (earliest, latest) timestamps across all sleep_level rows."""
    earliest: datetime | None = None
    latest: datetime | None = None
    for msg in level_msgs:
        raw = raw_field_values(msg)
        ts = _as_dt(raw.get(_F_TIMESTAMP))
        if ts is None:
            continue
        if earliest is None or ts < earliest:
            earliest = ts
        if latest is None or ts > latest:
            latest = ts
    return earliest, latest


# FIT epoch is 1989-12-31 00:00:00 UTC. Garmin watches store all absolute
# timestamps as uint32 seconds since this epoch.
_FIT_EPOCH = datetime(1989, 12, 31, tzinfo=UTC)


def _as_dt(v: Any) -> datetime | None:
    """Coerce a fitdecode field value into a UTC datetime, or None.

    Accepts:
        - `None`
        - `datetime` (returned as-is, made UTC if naive)
        - `int` interpreted as FIT-epoch seconds (Garmin's standard for
          absolute timestamps; values are typically > 6e8). We range-check
          to avoid mis-converting small relative offsets.
    """
    if v is None:
        return None
    if isinstance(v, datetime):
        if v.tzinfo is None:
            return v.replace(tzinfo=UTC)
        return v
    if isinstance(v, int) and v > 600_000_000:
        return _FIT_EPOCH + timedelta(seconds=v)
    return None
