-- garmin-dump schema, version 1.
-- All times stored as ISO-8601 UTC strings ("YYYY-MM-DDTHH:MM:SS+00:00") so SQLite's
-- datetime() functions work directly. Wellness daily uses date_local because it's a
-- calendar-day rollup; pair with local_tz only if it ever matters.

PRAGMA foreign_keys = ON;

-- ----------------------------------------------------------------------------------------
-- devices: one row per Garmin device that has ever been synced.
-- ----------------------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------------------
-- sync_log: source of truth for "is this file synced?". Dedup key is
-- (device_id, remote_parent, filename, size_bytes) — never the (unstable) MTP file ID.
-- ----------------------------------------------------------------------------------------
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
CREATE INDEX IF NOT EXISTS idx_sync_log_status            ON sync_log(status);
CREATE INDEX IF NOT EXISTS idx_sync_log_category          ON sync_log(category);
CREATE INDEX IF NOT EXISTS idx_sync_log_device_category   ON sync_log(device_id, category);
CREATE INDEX IF NOT EXISTS idx_sync_log_first_seen        ON sync_log(first_seen_utc);

-- ----------------------------------------------------------------------------------------
-- activities: one row per activity FIT file.
-- ----------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS activities (
    activity_id      INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER NOT NULL REFERENCES sync_log(sync_id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_activities_start         ON activities(start_time_utc);
CREATE INDEX IF NOT EXISTS idx_activities_device_start  ON activities(device_id, start_time_utc);
CREATE INDEX IF NOT EXISTS idx_activities_sport         ON activities(sport);

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
CREATE INDEX IF NOT EXISTS idx_laps_activity ON activity_laps(activity_id);

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
CREATE INDEX IF NOT EXISTS idx_records_activity_ts ON activity_records(activity_id, timestamp_utc);

-- ----------------------------------------------------------------------------------------
-- wellness_daily: one row per (device, calendar date local).
-- ----------------------------------------------------------------------------------------
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
CREATE INDEX IF NOT EXISTS idx_wellness_daily_date         ON wellness_daily(date_local);
CREATE INDEX IF NOT EXISTS idx_wellness_daily_device_date  ON wellness_daily(device_id, date_local);

-- ----------------------------------------------------------------------------------------
-- wellness_samples: tall key-value table for intraday measurements. Garmin's monitoring
-- fields are open-ended; columnizing now would force endless schema migrations.
-- ----------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wellness_samples (
    sample_id        INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id),
    sync_id          INTEGER REFERENCES sync_log(sync_id) ON DELETE SET NULL,
    timestamp_utc    TEXT NOT NULL,
    metric           TEXT NOT NULL,
    value            REAL,
    unit             TEXT,
    -- See sleep_sessions.local_offset_s. Per-sample because the wearer
    -- might cross a TZ boundary mid-day.
    local_offset_s   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_wellness_samples_metric_ts  ON wellness_samples(metric, timestamp_utc);
CREATE INDEX IF NOT EXISTS idx_wellness_samples_device_ts  ON wellness_samples(device_id, timestamp_utc);

-- ----------------------------------------------------------------------------------------
-- sleep_sessions / sleep_stages: best-effort. Most Instinct 3 sleep data lives in
-- unknown_NNN messages, so the canonical record is the raw .fit file on disk.
-- ----------------------------------------------------------------------------------------
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
    -- Signed seconds east-of-UTC for the local zone the watch was worn in
    -- (e.g. -25200 for PDT). Used by the viewer to render hour-of-day in
    -- the wearer's local time. NULL = unknown / fall back to system TZ.
    local_offset_s   INTEGER,
    UNIQUE (device_id, start_utc)
);
CREATE INDEX IF NOT EXISTS idx_sleep_sessions_start ON sleep_sessions(start_utc);

CREATE TABLE IF NOT EXISTS sleep_stages (
    stage_id         INTEGER PRIMARY KEY,
    sleep_id         INTEGER NOT NULL REFERENCES sleep_sessions(sleep_id) ON DELETE CASCADE,
    start_utc        TEXT NOT NULL,
    end_utc          TEXT NOT NULL,
    stage            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sleep_stages_sleep ON sleep_stages(sleep_id);

-- ----------------------------------------------------------------------------------------
-- unknown_fit_messages: catch-all so future parser passes can target the highest-volume
-- unknown message numbers without re-walking every FIT file.
-- ----------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS unknown_fit_messages (
    id                INTEGER PRIMARY KEY,
    sync_id           INTEGER NOT NULL REFERENCES sync_log(sync_id) ON DELETE CASCADE,
    msg_num           INTEGER NOT NULL,
    occurrence_count  INTEGER NOT NULL,
    sample_json       TEXT
);
CREATE INDEX IF NOT EXISTS idx_unknown_msgnum ON unknown_fit_messages(msg_num);

-- ----------------------------------------------------------------------------------------
-- runs: per-invocation audit log.
-- ----------------------------------------------------------------------------------------
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
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_utc);
