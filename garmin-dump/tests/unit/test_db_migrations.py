"""Tests for the SQLite migration runner."""

from __future__ import annotations

from pathlib import Path

from garmin_dump.db.connection import Database
from garmin_dump.db.migrations import CURRENT_VERSION, get_user_version


def test_fresh_db_applies_schema(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        assert get_user_version(db.conn) == CURRENT_VERSION
        # Spot-check a few tables exist
        for table in ("devices", "sync_log", "activities", "wellness_samples", "runs"):
            row = db.conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                (table,),
            ).fetchone()
            assert row is not None, f"missing table {table}"


def test_reopening_db_is_noop(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        first_version = get_user_version(db.conn)
    with Database(db_path) as db:
        assert get_user_version(db.conn) == first_version


def test_pragmas_set(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        mode = db.conn.execute("PRAGMA journal_mode").fetchone()[0]
        assert mode == "wal"
        fk = db.conn.execute("PRAGMA foreign_keys").fetchone()[0]
        assert fk == 1
