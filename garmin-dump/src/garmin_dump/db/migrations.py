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
CURRENT_VERSION = 2

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
