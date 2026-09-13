"""Tests for repairing `wellness_daily` rows written by the old rollup.

The monitoring rollup merges its accumulated columns by high-water mark, so a
later and more partial monitor file can never drag a finished day backwards.
That monotonicity is deliberate, and it has one consequence worth a test suite
of its own: re-ingesting correct data over a value an older parser got wrong
leaves the wrong value in place. A repair must therefore clear, then rebuild.

Two mechanisms do the clearing — the v3 migration (one-shot, on open) and
`ingest --reparse` (repeatable) — and both are checked here against the actual
inflated and collapsed numbers from the wearer's archive.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from monitor_builder import RUNNING, WALKING, MonitorFile

from garmin_dump.db.connection import Database
from garmin_dump.db.migrations import (
    ACCUMULATED_WELLNESS_COLUMNS,
    CURRENT_VERSION,
    apply_migrations,
    clear_accumulated_wellness,
    delete_empty_wellness_rows,
    get_user_version,
    set_user_version,
)
from tests.unit.conftest import MonitorHarness, seed_device

# Straight from the measured old-vs-correct table: 2026-09-11 was inflated by
# summing accumulated snapshots, 2026-09-09 was collapsed by last-file-wins.
INFLATED = ("2026-09-11", 28676, 14338)
COLLAPSED = ("2026-09-09", 242, 25966)


def _insert_legacy_row(
    conn: sqlite3.Connection,
    device_id: int,
    date_local: str,
    *,
    steps: int | None,
    resting_hr: int | None = 52,
    avg_stress: int | None = 31,
) -> None:
    """A `wellness_daily` row as the old rollup would have left it."""
    conn.execute(
        """
        INSERT INTO wellness_daily (
            device_id, date_local, steps, distance_m, active_kcal, bmr_kcal,
            floors_climbed, intensity_min, resting_hr, avg_stress, parsed_at_utc
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '2026-09-12T00:00:00Z')
        """,
        (device_id, date_local, steps, 19000.0, 900, 1500, 7, 120, resting_hr, avg_stress),
    )


def _row(conn: sqlite3.Connection, date_local: str):
    return conn.execute(
        "SELECT * FROM wellness_daily WHERE date_local = ?", (date_local,)
    ).fetchone()


# ---- the clearing primitive --------------------------------------------------------------


def test_clear_nulls_every_accumulated_column(tmp_path: Path) -> None:
    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, INFLATED[0], steps=INFLATED[1])

        assert clear_accumulated_wellness(db.conn) == 1

        row = _row(db.conn, INFLATED[0])
        for column in ACCUMULATED_WELLNESS_COLUMNS:
            assert row[column] is None, f"{column} survived the clear"


def test_clear_leaves_the_timestamp_bucketed_metrics_alone(tmp_path: Path) -> None:
    """HR / stress / SpO2 are bucketed by their own timestamps.

    Neither defect touched them, so a repair that threw them away would lose
    good data to fix a different column.
    """
    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(
            db.conn, device_id, INFLATED[0], steps=INFLATED[1], resting_hr=52, avg_stress=31
        )

        clear_accumulated_wellness(db.conn)

        row = _row(db.conn, INFLATED[0])
        assert row["resting_hr"] == 52
        assert row["avg_stress"] == 31


def test_clear_can_be_scoped_to_a_device(tmp_path: Path) -> None:
    with Database(tmp_path / "t.db") as db:
        keep = seed_device(db.conn, "1111111111")
        wipe = seed_device(db.conn, "2222222222")
        _insert_legacy_row(db.conn, keep, "2026-09-11", steps=1111)
        _insert_legacy_row(db.conn, wipe, "2026-09-10", steps=2222)

        assert clear_accumulated_wellness(db.conn, device_ids=(wipe,)) == 1

        assert _row(db.conn, "2026-09-11")["steps"] == 1111
        assert _row(db.conn, "2026-09-10")["steps"] is None


def test_clear_can_be_scoped_to_a_date_floor(tmp_path: Path) -> None:
    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, "2026-09-05", steps=500)
        _insert_legacy_row(db.conn, device_id, "2026-09-11", steps=28676)

        assert clear_accumulated_wellness(db.conn, since_date_local="2026-09-10") == 1

        assert _row(db.conn, "2026-09-05")["steps"] == 500
        assert _row(db.conn, "2026-09-11")["steps"] is None


def test_empty_rows_are_dropped_but_partial_ones_are_kept(tmp_path: Path) -> None:
    """A day that held only accumulated columns has nothing left to show."""
    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(
            db.conn, device_id, "2026-09-11", steps=28676, resting_hr=None, avg_stress=None
        )
        _insert_legacy_row(db.conn, device_id, "2026-09-10", steps=11266, resting_hr=52)

        clear_accumulated_wellness(db.conn)
        assert delete_empty_wellness_rows(db.conn) == 1

        assert _row(db.conn, "2026-09-11") is None, "row with no measurements left behind"
        assert _row(db.conn, "2026-09-10") is not None, "row still carrying HR was dropped"


# ---- the v3 migration --------------------------------------------------------------------


def _open_at_v2(path: Path) -> None:
    """Create a database and rewind it to schema v2, pre-repair."""
    with Database(path) as db:
        set_user_version(db.conn, 2)


def test_v3_migration_clears_a_legacy_database_on_open(tmp_path: Path) -> None:
    db_path = tmp_path / "legacy.db"
    _open_at_v2(db_path)

    with sqlite3.connect(db_path) as raw:
        raw.row_factory = sqlite3.Row
        device_id = seed_device(raw)
        _insert_legacy_row(raw, device_id, INFLATED[0], steps=INFLATED[1])
        _insert_legacy_row(raw, device_id, COLLAPSED[0], steps=COLLAPSED[1])
        raw.commit()

    with Database(db_path) as db:
        assert get_user_version(db.conn) == CURRENT_VERSION
        assert _row(db.conn, INFLATED[0])["steps"] is None, "inflated day not cleared"
        assert _row(db.conn, COLLAPSED[0])["steps"] is None, "collapsed day not cleared"
        # The rows survive; only the columns that need rebuilding were cleared.
        assert _row(db.conn, INFLATED[0])["resting_hr"] == 52


def test_v3_migration_is_idempotent_on_a_fresh_database(tmp_path: Path) -> None:
    db_path = tmp_path / "fresh.db"
    with Database(db_path) as db:
        assert get_user_version(db.conn) == CURRENT_VERSION
    with Database(db_path) as db:
        apply_migrations(db.conn)
        assert get_user_version(db.conn) == CURRENT_VERSION


def test_v3_migration_does_not_run_twice(tmp_path: Path) -> None:
    """A correct value written after the repair must not be cleared again."""
    db_path = tmp_path / "once.db"
    _open_at_v2(db_path)
    with Database(db_path) as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, INFLATED[0], steps=INFLATED[1])

    with Database(db_path) as db:  # v3 applies here
        db.conn.execute(
            "UPDATE wellness_daily SET steps = ? WHERE date_local = ?",
            (INFLATED[2], INFLATED[0]),
        )

    with Database(db_path) as db:  # already at v3, must be a no-op
        assert _row(db.conn, INFLATED[0])["steps"] == INFLATED[2]


# ---- clear-then-rebuild, end to end ------------------------------------------------------


def test_a_monotonic_merge_cannot_repair_without_clearing_first(
    monitor: MonitorHarness,
) -> None:
    """The trap this whole file exists for, stated as an executable claim.

    Re-ingesting the correct 14,338 over the corrupt 28,676 leaves 28,676; the
    same write after a clear lands. "Just re-run the pull" is not a repair.
    """
    _insert_legacy_row(monitor.conn, monitor.device_id, INFLATED[0], steps=INFLATED[1])

    mf = MonitorFile()
    mf.snapshot("2026-09-12T03:54", WALKING, steps=14315, duration_min=1254)
    mf.snapshot("2026-09-12T03:54", RUNNING, steps=23, duration_min=1254)
    monitor.ingest("M9BK5411.FIT", mf)

    assert monitor.day(INFLATED[0])["steps"] == INFLATED[1], (
        "the high-water merge is supposed to refuse to move a day down"
    )

    clear_accumulated_wellness(monitor.conn, device_ids=(monitor.device_id,))
    monitor.ingest("M9BK5412.FIT", mf)

    assert monitor.day(INFLATED[0])["steps"] == INFLATED[2]


def test_rebuild_restores_a_collapsed_day_from_two_files(
    monitor: MonitorHarness,
) -> None:
    """The collapse case: a partial file had overwritten a finished day."""
    _insert_legacy_row(monitor.conn, monitor.device_id, COLLAPSED[0], steps=COLLAPSED[1])

    clear_accumulated_wellness(monitor.conn, device_ids=(monitor.device_id,))
    monitor.ingest(
        "M9A00000.FIT",
        MonitorFile().snapshot("2026-09-09T16:02", WALKING, steps=242, duration_min=542),
    )
    monitor.ingest(
        "M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
        ),
    )

    assert monitor.day(COLLAPSED[0])["steps"] == COLLAPSED[2]


# ---- the reparse command -----------------------------------------------------------------


def test_reparse_clears_only_devices_with_monitor_files_in_scope(tmp_path: Path) -> None:
    """`--scope activity` must not clear the wellness rollup."""
    from rich.console import Console

    from garmin_dump.commands.ingest import IngestOptions, _clear_wellness_rollup

    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, INFLATED[0], steps=INFLATED[1])

        activity_only = [{"device_id": device_id, "category": "activity"}]
        assert (
            _clear_wellness_rollup(
                db, activity_only, IngestOptions(reparse=True), Console()
            )
            == 0
        )
        assert _row(db.conn, INFLATED[0])["steps"] == INFLATED[1]

        with_monitor = [{"device_id": device_id, "category": "monitor"}]
        assert (
            _clear_wellness_rollup(
                db, with_monitor, IngestOptions(reparse=True), Console()
            )
            == 1
        )
        assert _row(db.conn, INFLATED[0])["steps"] is None


def test_reparse_since_backs_the_date_floor_off_by_a_day(tmp_path: Path) -> None:
    """`--since` filters on when a file was seen, not the days it describes.

    The end-of-day snapshot in a file first seen on the 12th reports the 11th,
    so the floor has to reach one day further back or that day is never rebuilt.
    """
    from rich.console import Console

    from garmin_dump.commands.ingest import IngestOptions, _clear_wellness_rollup

    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, "2026-09-11", steps=28676)
        _insert_legacy_row(db.conn, device_id, "2026-09-10", steps=31)
        _insert_legacy_row(db.conn, device_id, "2026-09-01", steps=4000)

        rows = [{"device_id": device_id, "category": "monitor"}]
        cleared = _clear_wellness_rollup(
            db, rows, IngestOptions(reparse=True, since="2026-09-11"), Console()
        )

        assert cleared == 2, "the 10th must be in range so the 11th's snapshot can land"
        assert _row(db.conn, "2026-09-11")["steps"] is None
        assert _row(db.conn, "2026-09-10")["steps"] is None
        assert _row(db.conn, "2026-09-01")["steps"] == 4000, "outside the window"


def test_reparse_with_an_unparseable_since_clears_everything(tmp_path: Path) -> None:
    """Better to over-clear (NULL reads as unknown) than to skip the repair."""
    from rich.console import Console

    from garmin_dump.commands.ingest import IngestOptions, _clear_wellness_rollup

    with Database(tmp_path / "t.db") as db:
        device_id = seed_device(db.conn)
        _insert_legacy_row(db.conn, device_id, "2026-09-11", steps=28676)

        rows = [{"device_id": device_id, "category": "monitor"}]
        assert (
            _clear_wellness_rollup(
                db, rows, IngestOptions(reparse=True, since="not-a-date"), Console()
            )
            == 1
        )
        assert _row(db.conn, "2026-09-11")["steps"] is None


@pytest.mark.parametrize("column", ACCUMULATED_WELLNESS_COLUMNS)
def test_every_accumulated_column_exists_on_the_table(tmp_path: Path, column: str) -> None:
    """Guards the shared column list against drifting from the schema."""
    with Database(tmp_path / "t.db") as db:
        names = {r[1] for r in db.conn.execute("PRAGMA table_info(wellness_daily)")}
    assert column in names
