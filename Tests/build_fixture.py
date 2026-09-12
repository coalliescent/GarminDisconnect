#!/usr/bin/env python3
"""Build Tests/fixtures/tiny.db — a small canned SQLite archive that mirrors the
garmin-dump schema. Used by DatabaseTests and as a development fallback when no
real watch archive is available.

Run this once after editing; commit the resulting tiny.db to the repo.

The fixture contents are deliberately minimal but exercise every code path the
viewer cares about:
    - 2 devices (so multi-device picker is testable)
    - 7 wellness_daily rows for primary device, with TWO calendar gaps in the
      middle (so DateUtil.fillGaps() has something to detect)
    - 30 wellness_samples rows of mixed metrics
    - 3 activities (run, walk, swim) with realistic field values
    - 30 activity_records on the run and 30 on the walk (small GPS traces;
      the walk starts 24h later and continues the run's route, so the
      multi-activity grouping code has a realistic two-member case)
    - 1 sleep_session with 4 sleep_stages
    - 3 runs rows so the Sync tab has something to display
"""

import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path(__file__).parent / "fixtures" / "tiny.db"
SCHEMA_VERSION = 1

# Pin "now" so the fixture is reproducible across runs. The viewer queries with
# date('now') so changing this changes which days appear "recent".
NOW = datetime(2026, 4, 8, 12, 0, 0, tzinfo=timezone.utc)


def iso(dt):
    return dt.replace(microsecond=0).isoformat()


def main():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    conn.executescript(SCHEMA_SQL)
    conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    # ---- devices ----
    cur = conn.cursor()
    cur.executemany(
        """INSERT INTO devices (serial, unit_id, part_number, model, software_version,
                                first_seen_utc, last_seen_utc)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        [
            ("3509067685", "3509067685", "006-B5023-00", "Instinct 3 - 45mm, Solar",
             "521", iso(NOW - timedelta(days=120)), iso(NOW)),
            ("9999999999", "9999999999", "006-B0000-00", "Test Device",
             "100", iso(NOW - timedelta(days=30)), iso(NOW - timedelta(days=2))),
        ],
    )
    primary_id = cur.execute(
        "SELECT device_id FROM devices WHERE serial=?", ("3509067685",)
    ).fetchone()[0]

    # ---- wellness_daily ----
    # 7 calendar days starting 10 days ago, with day 4 and day 5 missing (gaps).
    base_day = (NOW - timedelta(days=10)).date()
    wellness_rows = []
    for offset in range(11):
        if offset in (4, 5):  # gap days — no row inserted at all
            continue
        d = base_day + timedelta(days=offset)
        rh = 50 + (offset % 3)
        wellness_rows.append((
            primary_id, None, d.isoformat(),
            8000 + offset * 500, 6500.0 + offset * 100, 350 + offset * 20,
            1500, 8 + offset, 25 + offset * 5,
            rh, 45, 110 + offset, 30 + offset * 2,
            10, 95, 96, 14.5,
            "{}", iso(NOW),
        ))
    cur.executemany(
        """INSERT INTO wellness_daily
            (device_id, sync_id, date_local, steps, distance_m, active_kcal, bmr_kcal,
             floors_climbed, intensity_min, resting_hr, min_hr, max_hr, avg_stress,
             body_battery_min, body_battery_max, spo2_avg, respiration_avg,
             raw_json, parsed_at_utc)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        wellness_rows,
    )

    # ---- wellness_samples ----
    sample_rows = []
    for h in range(24):
        ts = (NOW - timedelta(days=1)).replace(hour=h, minute=0, second=0, microsecond=0)
        sample_rows.append((primary_id, None, iso(ts), "heart_rate", 60.0 + h, "bpm"))
        sample_rows.append((primary_id, None, iso(ts), "stress_level", 20.0 + h, None))
    cur.executemany(
        """INSERT INTO wellness_samples
            (device_id, sync_id, timestamp_utc, metric, value, unit)
           VALUES (?, ?, ?, ?, ?, ?)""",
        sample_rows,
    )

    # ---- activities ----
    activities = [
        # (sport, duration_s, distance_m, days_ago)
        ("running", 1820, 5230.0, 2),
        ("walking",  720, 1100.0, 1),
        ("swimming", 1500, 1500.0, 4),
    ]
    activity_ids = []
    for i, (sport, dur, dist, days_ago) in enumerate(activities):
        start = NOW - timedelta(days=days_ago, hours=8)
        end = start + timedelta(seconds=dur)
        cur.execute(
            """INSERT INTO activities (
                device_id, sync_id, file_sha256, start_time_utc, end_time_utc,
                sport, sub_sport,
                total_elapsed_s, total_timer_s, total_distance_m, total_calories,
                avg_hr, max_hr, avg_cadence, max_cadence,
                avg_speed_mps, max_speed_mps, total_ascent_m, total_descent_m,
                training_load, intensity_factor, raw_session_json, parsed_at_utc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                primary_id, None, f"sha-fixture-{i:08x}",
                iso(start), iso(end),
                sport, "generic",
                float(dur), float(dur), dist, int(dist * 0.06),
                145, 168, 75.0, 82.0,
                dist / dur, dist / dur * 1.4, 30.0, 30.0,
                25.5, 0.85, "{}", iso(NOW),
            ),
        )
        activity_ids.append(cur.lastrowid)

    # ---- activity_records (only for the run, 30 1Hz samples) ----
    run_id = activity_ids[0]
    record_rows = []
    base_lat = 45.5236
    base_lon = -122.6750
    start_run = NOW - timedelta(days=2, hours=8)
    for i in range(30):
        ts = start_run + timedelta(seconds=i)
        record_rows.append((
            run_id, iso(ts), float(i),
            base_lat + i * 0.00005,
            base_lon + i * 0.00005,
            10.0 + i * 0.1,  # altitude
            float(i * 3),    # distance
            2.8,             # speed
            140 + (i % 10),  # hr
            85,              # cadence
            None,            # power
            18.5,            # temp
        ))
    # ---- activity_records (the walk, 30 1Hz samples) ----
    #
    # The walk starts exactly 24h after the run and its GPS trail picks up
    # where the run's left off, so run+walk is a realistic stand-in for the
    # thing multi-selection exists for: one outing split across two files,
    # a day apart. ActivityGroupTests leans on both of those facts (the
    # 86400s offset and the chained route), so don't retime it casually.
    walk_id = activity_ids[1]
    start_walk = NOW - timedelta(days=1, hours=8)
    walk_lat = base_lat + 29 * 0.00005
    walk_lon = base_lon + 29 * 0.00005
    for i in range(30):
        ts = start_walk + timedelta(seconds=i)
        record_rows.append((
            walk_id, iso(ts), float(i),
            walk_lat + i * 0.00003,
            walk_lon + i * 0.00003,
            13.0 + i * 0.05,  # altitude
            float(i * 2),     # distance — 2 m/s, restarts at zero
            1.9,              # speed
            110 + (i % 5),    # hr — comfortably a zone below the run
            60,               # cadence
            None,             # power
            17.0,             # temp
        ))

    cur.executemany(
        """INSERT INTO activity_records (
            activity_id, timestamp_utc, elapsed_s, lat_deg, lon_deg, altitude_m,
            distance_m, speed_mps, heart_rate, cadence, power_w, temperature_c)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        record_rows,
    )

    # ---- activity_laps (one lap on the run) ----
    cur.execute(
        """INSERT INTO activity_laps (
            activity_id, lap_index, start_time_utc, total_elapsed_s, total_timer_s,
            total_distance_m, avg_hr, max_hr, avg_speed_mps, max_speed_mps,
            total_ascent_m, total_descent_m, raw_lap_json)
           VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}')""",
        (run_id, iso(start_run), 1820.0, 1820.0, 5230.0, 145, 168, 2.87, 4.0, 30.0, 30.0),
    )

    # ---- sleep_sessions + sleep_stages ----
    sleep_start = (NOW - timedelta(days=1)).replace(hour=23, minute=15, second=0, microsecond=0)
    sleep_end = NOW.replace(hour=6, minute=45, second=0, microsecond=0)
    cur.execute(
        """INSERT INTO sleep_sessions (
            device_id, sync_id, start_utc, end_utc, duration_s, sleep_score,
            deep_s, light_s, rem_s, awake_s,
            avg_hr, avg_respiration, avg_spo2, avg_stress, raw_json, parsed_at_utc)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            primary_id, None, iso(sleep_start), iso(sleep_end),
            int((sleep_end - sleep_start).total_seconds()),
            82, 4500, 12_000, 6_000, 1_500,
            55, 14.0, 95, 18, "{}", iso(NOW),
        ),
    )
    sleep_id = cur.lastrowid

    stages = [
        ("light",  sleep_start, sleep_start + timedelta(minutes=15)),
        ("deep",   sleep_start + timedelta(minutes=15), sleep_start + timedelta(hours=2)),
        ("rem",    sleep_start + timedelta(hours=2), sleep_start + timedelta(hours=4)),
        ("light",  sleep_start + timedelta(hours=4), sleep_end),
    ]
    cur.executemany(
        """INSERT INTO sleep_stages (sleep_id, start_utc, end_utc, stage)
           VALUES (?, ?, ?, ?)""",
        [(sleep_id, iso(s), iso(e), name) for (name, s, e) in stages],
    )

    # ---- runs ----
    cur.executemany(
        """INSERT INTO runs (started_utc, finished_utc, subcommand, argv_json,
                              device_id, files_seen, files_downloaded, bytes_downloaded,
                              files_deleted, errors_count, exit_code)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        [
            (iso(NOW - timedelta(days=2, minutes=5)), iso(NOW - timedelta(days=2)),
             "pull", '["pull"]', primary_id, 318, 318, 12_500_000, 0, 0, 0),
            (iso(NOW - timedelta(days=1, minutes=2)), iso(NOW - timedelta(days=1)),
             "pull", '["pull"]', primary_id, 318, 5, 200_000, 0, 0, 0),
            (iso(NOW - timedelta(hours=2, minutes=1)), iso(NOW - timedelta(hours=2)),
             "status", '["status"]', primary_id, 0, 0, 0, 0, 0, 0),
        ],
    )

    conn.commit()
    conn.close()
    print(f"wrote {DB_PATH}")


SCHEMA_SQL = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
    device_id        INTEGER PRIMARY KEY,
    serial           TEXT NOT NULL UNIQUE,
    unit_id          TEXT,
    part_number      TEXT,
    model            TEXT,
    software_version TEXT,
    first_seen_utc   TEXT NOT NULL,
    last_seen_utc    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_log (
    sync_id              INTEGER PRIMARY KEY,
    device_id            INTEGER NOT NULL REFERENCES devices(device_id),
    remote_parent        TEXT NOT NULL,
    filename             TEXT NOT NULL,
    size_bytes           INTEGER NOT NULL,
    sha256               TEXT,
    local_path           TEXT,
    category             TEXT NOT NULL,
    status               TEXT NOT NULL,
    first_seen_utc       TEXT NOT NULL,
    downloaded_utc       TEXT,
    verified_utc         TEXT,
    deleted_remote_utc   TEXT,
    parser_error         TEXT,
    error_message        TEXT,
    UNIQUE (device_id, remote_parent, filename, size_bytes)
);

CREATE TABLE IF NOT EXISTS activities (
    activity_id      INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER REFERENCES sync_log(sync_id) ON DELETE CASCADE,
    file_sha256      TEXT NOT NULL,
    start_time_utc   TEXT NOT NULL,
    end_time_utc     TEXT,
    sport            TEXT,
    sub_sport        TEXT,
    total_elapsed_s  REAL,
    total_timer_s    REAL,
    total_distance_m REAL,
    total_calories   INTEGER,
    avg_hr           INTEGER,
    max_hr           INTEGER,
    avg_cadence      REAL,
    max_cadence      REAL,
    avg_speed_mps    REAL,
    max_speed_mps    REAL,
    total_ascent_m   REAL,
    total_descent_m  REAL,
    training_load    REAL,
    intensity_factor REAL,
    raw_session_json TEXT,
    parsed_at_utc    TEXT NOT NULL,
    UNIQUE (device_id, file_sha256)
);

CREATE TABLE IF NOT EXISTS activity_laps (
    lap_id           INTEGER PRIMARY KEY,
    activity_id      INTEGER NOT NULL REFERENCES activities(activity_id) ON DELETE CASCADE,
    lap_index        INTEGER NOT NULL,
    start_time_utc   TEXT NOT NULL,
    total_elapsed_s  REAL,
    total_timer_s    REAL,
    total_distance_m REAL,
    avg_hr           INTEGER,
    max_hr           INTEGER,
    avg_speed_mps    REAL,
    max_speed_mps    REAL,
    total_ascent_m   REAL,
    total_descent_m  REAL,
    raw_lap_json     TEXT,
    UNIQUE (activity_id, lap_index)
);

CREATE TABLE IF NOT EXISTS activity_records (
    record_id        INTEGER PRIMARY KEY,
    activity_id      INTEGER NOT NULL REFERENCES activities(activity_id) ON DELETE CASCADE,
    timestamp_utc    TEXT NOT NULL,
    elapsed_s        REAL,
    lat_deg          REAL,
    lon_deg          REAL,
    altitude_m       REAL,
    distance_m       REAL,
    speed_mps        REAL,
    heart_rate       INTEGER,
    cadence          INTEGER,
    power_w          INTEGER,
    temperature_c    REAL
);

CREATE TABLE IF NOT EXISTS wellness_daily (
    wellness_id      INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER REFERENCES sync_log(sync_id) ON DELETE SET NULL,
    date_local       TEXT NOT NULL,
    steps            INTEGER,
    distance_m       REAL,
    active_kcal      INTEGER,
    bmr_kcal         INTEGER,
    floors_climbed   INTEGER,
    intensity_min    INTEGER,
    resting_hr       INTEGER,
    min_hr           INTEGER,
    max_hr           INTEGER,
    avg_stress       INTEGER,
    body_battery_min INTEGER,
    body_battery_max INTEGER,
    spo2_avg         INTEGER,
    respiration_avg  REAL,
    raw_json         TEXT,
    parsed_at_utc    TEXT NOT NULL,
    UNIQUE (device_id, date_local)
);

CREATE TABLE IF NOT EXISTS wellness_samples (
    sample_id        INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER REFERENCES sync_log(sync_id) ON DELETE SET NULL,
    timestamp_utc    TEXT NOT NULL,
    metric           TEXT NOT NULL,
    value            REAL,
    unit             TEXT
);

CREATE TABLE IF NOT EXISTS sleep_sessions (
    sleep_id         INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER REFERENCES sync_log(sync_id) ON DELETE SET NULL,
    start_utc        TEXT NOT NULL,
    end_utc          TEXT NOT NULL,
    duration_s       INTEGER,
    sleep_score      INTEGER,
    deep_s           INTEGER,
    light_s          INTEGER,
    rem_s            INTEGER,
    awake_s          INTEGER,
    avg_hr           INTEGER,
    avg_respiration  REAL,
    avg_spo2         INTEGER,
    avg_stress       INTEGER,
    raw_json         TEXT,
    parsed_at_utc    TEXT NOT NULL,
    UNIQUE (device_id, start_utc)
);

CREATE TABLE IF NOT EXISTS sleep_stages (
    stage_id         INTEGER PRIMARY KEY,
    sleep_id         INTEGER NOT NULL REFERENCES sleep_sessions(sleep_id) ON DELETE CASCADE,
    start_utc        TEXT NOT NULL,
    end_utc          TEXT NOT NULL,
    stage            TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS unknown_fit_messages (
    id                INTEGER PRIMARY KEY,
    sync_id           INTEGER NOT NULL REFERENCES sync_log(sync_id) ON DELETE CASCADE,
    msg_num           INTEGER NOT NULL,
    occurrence_count  INTEGER NOT NULL,
    sample_json       TEXT
);

CREATE TABLE IF NOT EXISTS runs (
    run_id           INTEGER PRIMARY KEY,
    started_utc      TEXT NOT NULL,
    finished_utc     TEXT,
    subcommand       TEXT NOT NULL,
    argv_json        TEXT NOT NULL,
    device_id        INTEGER REFERENCES devices(device_id),
    files_seen       INTEGER NOT NULL DEFAULT 0,
    files_downloaded INTEGER NOT NULL DEFAULT 0,
    bytes_downloaded INTEGER NOT NULL DEFAULT 0,
    files_deleted    INTEGER NOT NULL DEFAULT 0,
    errors_count     INTEGER NOT NULL DEFAULT 0,
    exit_code        INTEGER
);
"""


if __name__ == "__main__":
    main()
