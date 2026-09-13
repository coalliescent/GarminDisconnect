"""Schema migrations driven by `PRAGMA user_version`.

Migration policy:
    - schema.sql contains the canonical v1 DDL using `IF NOT EXISTS` so it's idempotent.
    - Future migrations are appended to MIGRATIONS as `(target_version, sql_or_callable)`.
    - On open, we read PRAGMA user_version and apply any migration whose target is higher.
    - We never downgrade. If on-disk version > known max, we raise SchemaVersionError.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Callable
from pathlib import Path

from garmin_dump.errors import SchemaVersionError

SCHEMA_PATH = Path(__file__).with_name("schema.sql")
CURRENT_VERSION = 3

MigrationFn = Callable[[sqlite3.Connection], None]


def _migration_v1(conn: sqlite3.Connection) -> None:
    """Apply the initial schema from schema.sql."""
    sql = SCHEMA_PATH.read_text(encoding="utf-8")
    conn.executescript(sql)


def _migration_v2(conn: sqlite3.Connection) -> None:
    """Add `local_offset_s` columns so the viewer can render times in the
    user's local zone (the one their watch was worn in) instead of UTC.

    The column is the offset in seconds between local time and UTC, signed
    east-of-UTC positive (e.g. `-25200` for PDT). It's per-row because the
    user might travel between days. The viewer reads it via:

        local_dt = utc_dt + timedelta(seconds=local_offset_s)

    Falling back to `TimeZone.current` when the column is NULL.
    """
    # We ADD COLUMN if-needed because schema.sql at HEAD already has the
    # column, so on a *fresh* database the v1 migration installs it and the
    # v2 migration would otherwise fail with "duplicate column name".
    _add_column_if_missing(conn, "sleep_sessions", "local_offset_s", "INTEGER")
    _add_column_if_missing(conn, "wellness_samples", "local_offset_s", "INTEGER")


# Columns of `wellness_daily` that the monitoring rollup merges by high-water
# mark. Shared with `commands/ingest.py`, which clears the same set on a
# `--reparse` so a future rollup change can also be rebuilt from disk.
ACCUMULATED_WELLNESS_COLUMNS = (
    "steps",
    "distance_m",
    "active_kcal",
    "bmr_kcal",
    "floors_climbed",
    "intensity_min",
)

# Every column that carries a measurement, as opposed to bookkeeping. A row
# with all of these NULL holds nothing the viewer can draw.
_WELLNESS_METRIC_COLUMNS = (
    *ACCUMULATED_WELLNESS_COLUMNS,
    "resting_hr",
    "min_hr",
    "max_hr",
    "avg_stress",
    "body_battery_min",
    "body_battery_max",
    "spo2_avg",
    "respiration_avg",
)


def clear_accumulated_wellness(
    conn: sqlite3.Connection,
    *,
    device_ids: tuple[int, ...] | None = None,
    since_date_local: str | None = None,
) -> int:
    """NULL the high-water-mark columns of `wellness_daily`, returning rows hit.

    The rollup's cross-file merge is deliberately monotonic — a later, more
    partial file must never drag a finished day downwards — which also means it
    can never lower a value a previous parser got wrong. Re-ingesting correct
    data over a corrupt row leaves the corrupt row. So a repair has to clear
    first and rebuild second, and this is the clearing half.

    Scope to `device_ids` / `since_date_local` to bound the damage when only
    part of the archive is being replayed; clearing a day whose files are not
    in the replay set leaves it NULL, which reads as "unknown" rather than
    wrong.
    """
    sets = ", ".join(f"{c} = NULL" for c in ACCUMULATED_WELLNESS_COLUMNS)
    sql = f"UPDATE wellness_daily SET {sets}"
    where: list[str] = []
    params: list[object] = []
    if device_ids:
        where.append(f"device_id IN ({','.join('?' for _ in device_ids)})")
        params.extend(device_ids)
    if since_date_local:
        where.append("date_local >= ?")
        params.append(since_date_local)
    if where:
        sql += " WHERE " + " AND ".join(where)
    cur = conn.execute(sql, params)
    return cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0


def delete_empty_wellness_rows(conn: sqlite3.Connection) -> int:
    """Drop `wellness_daily` rows left with no measurement at all."""
    nulls = " AND ".join(f"{c} IS NULL" for c in _WELLNESS_METRIC_COLUMNS)
    cur = conn.execute(f"DELETE FROM wellness_daily WHERE {nulls}")
    return cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0


def _migration_v3(conn: sqlite3.Connection) -> None:
    """Clear the monitoring rollup's accumulated columns so they get rebuilt.

    Two defects in the old `monitoring` rollup wrote every one of these values:

      * accumulated per-activity_type snapshots were summed as if they were
        increments, inflating a day (one 14,338-step day read 28,676); and
      * a day written by several overlapping files took whichever file landed
        last, so a finished day could be overwritten by a partial one
        (a 25,966-step day read 242).

    Both are fixed in `ingest/monitoring.py`, but the new merge is monotonic and
    therefore cannot pull an inflated legacy value back down. NULLing the
    columns here lets the very next `garmin-dump ingest` repopulate them from
    the FIT files already on disk — no watch required. Rows that held nothing
    but those columns are dropped so the viewer sees no empty days.

    The per-day HR / stress / SpO2 / body-battery aggregates are untouched: they
    are bucketed by their own timestamps, which neither defect affected.

    This is a one-shot repair, not a schema change. It is safe to have run on a
    database whose rows were already correct — it only costs one re-ingest.
    """
    clear_accumulated_wellness(conn)
    delete_empty_wellness_rows(conn)


def _add_column_if_missing(
    conn: sqlite3.Connection, table: str, column: str, decl: str
) -> None:
    """Idempotent ALTER TABLE ADD COLUMN. Safe to run on a database that
    already has the column (e.g. a fresh install whose v1 schema.sql is
    already up to date with later schema additions).
    """
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    existing = {r[1] for r in rows}  # column name is at index 1
    if column in existing:
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")


MIGRATIONS: list[tuple[int, MigrationFn]] = [
    (1, _migration_v1),
    (2, _migration_v2),
    (3, _migration_v3),
]


def get_user_version(conn: sqlite3.Connection) -> int:
    cur = conn.execute("PRAGMA user_version")
    row = cur.fetchone()
    return int(row[0]) if row is not None else 0


def set_user_version(conn: sqlite3.Connection, version: int) -> None:
    # PRAGMA user_version doesn't accept parameter binding; the value is an integer
    # we control, so f-string is safe.
    conn.execute(f"PRAGMA user_version = {int(version)}")


def apply_migrations(conn: sqlite3.Connection) -> None:
    """Bring the database up to CURRENT_VERSION. Idempotent.

    Note: we deliberately do not wrap migrations in an explicit BEGIN/COMMIT.
    `sqlite3.Connection.executescript()` issues an implicit COMMIT before running its
    script, which would yank the transaction out from under us. Each migration is
    expected to be self-recoverable (schema.sql uses IF NOT EXISTS for everything),
    and PRAGMA user_version is the source of truth for whether a version was applied.
    """
    current = get_user_version(conn)
    if current > CURRENT_VERSION:
        raise SchemaVersionError(
            f"on-disk schema is version {current} but this binary only knows up to "
            f"{CURRENT_VERSION}. Upgrade garmin-dump or use a newer database."
        )
    for target, fn in MIGRATIONS:
        if target <= current:
            continue
        fn(conn)
        set_user_version(conn, target)
        current = target
