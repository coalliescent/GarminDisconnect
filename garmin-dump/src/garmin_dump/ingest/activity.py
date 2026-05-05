"""Activity FIT file ingestion.

A typical activity file contains:
    - 1 file_id (mandatory) with type='activity'
    - 1 device_info
    - many record (1Hz GPS/HR/cadence samples)
    - several lap (one per lap; for non-multisport activities, often just 1)
    - 1 session (the activity-level rollup)
    - 1 activity

We store the session as the activity row, the laps as `activity_laps`, and the records
as `activity_records`. Re-ingesting the same file (same SHA-256) is a no-op for the
activities table thanks to UNIQUE(device_id, file_sha256); we delete-then-re-insert
the laps + records via FK CASCADE during reparse.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from typing import Any

from garmin_dump.db.repo import json_dumps_safe, utc_now_iso
from garmin_dump.ingest.fit_reader import MessageBuckets, message_to_dict, safe_get

# Records are batched into the DB to keep WAL pressure down.
RECORD_BATCH = 1000


def ingest_activity(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    file_sha256: str,
    buckets: MessageBuckets,
) -> int | None:
    """Ingest an activity file's buckets. Returns the activity_id, or None if no session.

    Idempotent under the (device_id, file_sha256) UNIQUE constraint: if a row already
    exists with the same hash, we delete it (cascading laps + records) and re-insert.
    """
    sessions = buckets.get("session")
    if not sessions:
        return None

    # Delete any prior parse of this exact file content. CASCADE removes laps + records.
    conn.execute(
        "DELETE FROM activities WHERE device_id = ? AND file_sha256 = ?",
        (device_id, file_sha256),
    )

    session = sessions[0]
    activity_id = _insert_activity(
        conn,
        sync_id=sync_id,
        device_id=device_id,
        file_sha256=file_sha256,
        session=session,
    )
    _insert_laps(conn, activity_id, buckets)
    _insert_records(conn, activity_id, buckets)
    return activity_id


def _insert_activity(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    file_sha256: str,
    session: Any,
) -> int:
    start = _iso(safe_get(session, "start_time"))
    end = _iso(safe_get(session, "timestamp"))
    cur = conn.execute(
        """
        INSERT INTO activities (
            device_id, sync_id, file_sha256,
            start_time_utc, end_time_utc,
            sport, sub_sport,
            total_elapsed_s, total_timer_s, total_distance_m, total_calories,
            avg_hr, max_hr, avg_cadence, max_cadence,
            avg_speed_mps, max_speed_mps,
            total_ascent_m, total_descent_m,
            training_load, intensity_factor,
            raw_session_json, parsed_at_utc
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            device_id,
            sync_id,
            file_sha256,
            start or utc_now_iso(),
            end,
            safe_get(session, "sport"),
            safe_get(session, "sub_sport"),
            _num(safe_get(session, "total_elapsed_time")),
            _num(safe_get(session, "total_timer_time")),
            _num(safe_get(session, "total_distance")),
            _int(safe_get(session, "total_calories")),
            _int(safe_get(session, "avg_heart_rate")),
            _int(safe_get(session, "max_heart_rate")),
            _num(safe_get(session, "avg_cadence")),
            _num(safe_get(session, "max_cadence")),
            _num(safe_get(session, "avg_speed") or safe_get(session, "enhanced_avg_speed")),
            _num(safe_get(session, "max_speed") or safe_get(session, "enhanced_max_speed")),
            _num(safe_get(session, "total_ascent")),
            _num(safe_get(session, "total_descent")),
            _num(safe_get(session, "training_load_peak")),
            _num(safe_get(session, "intensity_factor")),
            json_dumps_safe(message_to_dict(session)),
            utc_now_iso(),
        ),
    )
    return int(cur.lastrowid or 0)


def _insert_laps(conn: sqlite3.Connection, activity_id: int, buckets: MessageBuckets) -> None:
    laps = buckets.get("lap")
    rows = []
    for idx, lap in enumerate(laps):
        rows.append(
            (
                activity_id,
                idx,
                _iso(safe_get(lap, "start_time")) or utc_now_iso(),
                _num(safe_get(lap, "total_elapsed_time")),
                _num(safe_get(lap, "total_timer_time")),
                _num(safe_get(lap, "total_distance")),
                _int(safe_get(lap, "avg_heart_rate")),
                _int(safe_get(lap, "max_heart_rate")),
                _num(safe_get(lap, "avg_speed") or safe_get(lap, "enhanced_avg_speed")),
                _num(safe_get(lap, "max_speed") or safe_get(lap, "enhanced_max_speed")),
                _num(safe_get(lap, "total_ascent")),
                _num(safe_get(lap, "total_descent")),
                json_dumps_safe(message_to_dict(lap)),
            )
        )
    if rows:
        conn.executemany(
            """
            INSERT INTO activity_laps (
                activity_id, lap_index, start_time_utc,
                total_elapsed_s, total_timer_s, total_distance_m,
                avg_hr, max_hr, avg_speed_mps, max_speed_mps,
                total_ascent_m, total_descent_m, raw_lap_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )


def _insert_records(conn: sqlite3.Connection, activity_id: int, buckets: MessageBuckets) -> None:
    records = buckets.get("record")
    if not records:
        return
    batch: list[tuple[Any, ...]] = []
    for r in records:
        batch.append(
            (
                activity_id,
                _iso(safe_get(r, "timestamp")) or utc_now_iso(),
                _num(safe_get(r, "elapsed_time")),
                _num(_semicircles_to_deg(safe_get(r, "position_lat"))),
                _num(_semicircles_to_deg(safe_get(r, "position_long"))),
                _num(safe_get(r, "altitude") or safe_get(r, "enhanced_altitude")),
                _num(safe_get(r, "distance")),
                _num(safe_get(r, "speed") or safe_get(r, "enhanced_speed")),
                _int(safe_get(r, "heart_rate")),
                _int(safe_get(r, "cadence")),
                _int(safe_get(r, "power")),
                _num(safe_get(r, "temperature")),
            )
        )
        if len(batch) >= RECORD_BATCH:
            _flush_records(conn, batch)
            batch = []
    if batch:
        _flush_records(conn, batch)


def _flush_records(conn: sqlite3.Connection, batch: list[tuple[Any, ...]]) -> None:
    conn.executemany(
        """
        INSERT INTO activity_records (
            activity_id, timestamp_utc, elapsed_s,
            lat_deg, lon_deg, altitude_m, distance_m, speed_mps,
            heart_rate, cadence, power_w, temperature_c
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        batch,
    )


# ---- coercion helpers ------------------------------------------------------------------


def _iso(v: Any) -> str | None:
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.isoformat()
    return str(v)


def _num(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _int(v: Any) -> int | None:
    if v is None:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# Garmin stores latitude/longitude as semicircles: degrees * (2^31 / 180).
_SEMICIRCLE_TO_DEG = 180.0 / (1 << 31)


def _semicircles_to_deg(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v) * _SEMICIRCLE_TO_DEG
    except (TypeError, ValueError):
        return None
