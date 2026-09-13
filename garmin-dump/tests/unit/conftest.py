"""Shared helpers for the wellness-rollup tests.

Puts `tests/fixtures` on the path so the FIT builders are importable, and
provides the one harness both rollup test modules need: seed a device, write a
built monitoring file to disk, register it in `sync_log` as verified, and run
`ingest_monitoring` over it exactly as the dispatcher would.
"""

from __future__ import annotations

import sqlite3
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest

from garmin_dump.db.connection import Database
from garmin_dump.db.repo import (
    DeviceUpsert,
    SyncKey,
    mark_sync_verified,
    upsert_device,
    upsert_sync_pending,
)
from garmin_dump.ingest.monitoring import ingest_monitoring

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fixtures"))

from monitor_builder import MonitorFile


@dataclass
class MonitorHarness:
    """A database with one device, plus a place to write monitoring files."""

    db: Database
    device_id: int
    tmp_path: Path

    @property
    def conn(self) -> sqlite3.Connection:
        return self.db.conn

    def new_file(self) -> MonitorFile:
        return MonitorFile()

    def ingest(self, name: str, mf: MonitorFile) -> None:
        """Write `mf` to disk and ingest it as a verified monitor sync."""
        path = mf.write(self.tmp_path / name)
        sync_id = upsert_sync_pending(
            self.conn,
            SyncKey(
                device_id=self.device_id,
                remote_parent="Monitor",
                filename=name,
                size_bytes=path.stat().st_size,
            ),
            category="monitor",
        )
        mark_sync_verified(
            self.conn, sync_id, sha256=name.ljust(64, "0")[:64], local_path=str(path)
        )
        ingest_monitoring(
            self.conn, sync_id=sync_id, device_id=self.device_id, path=path
        )

    def day(self, date_local: str) -> sqlite3.Row | None:
        return self.conn.execute(
            "SELECT * FROM wellness_daily WHERE date_local = ?", (date_local,)
        ).fetchone()

    def all_days(self) -> list[str]:
        rows = self.conn.execute(
            "SELECT date_local FROM wellness_daily ORDER BY date_local"
        ).fetchall()
        return [r["date_local"] for r in rows]

    def samples(self, metric: str) -> list[float]:
        rows = self.conn.execute(
            "SELECT value FROM wellness_samples WHERE metric = ? ORDER BY sample_id",
            (metric,),
        ).fetchall()
        return [r["value"] for r in rows]


def seed_device(conn: sqlite3.Connection, serial: str = "3509067685") -> int:
    return upsert_device(
        conn,
        DeviceUpsert(
            serial=serial,
            unit_id=f"unit_{serial}",
            part_number=None,
            model="Instinct 3",
            software_version="521",
        ),
    )


@pytest.fixture
def monitor(tmp_path: Path) -> Iterator[MonitorHarness]:
    with Database(tmp_path / "test.db") as database:
        yield MonitorHarness(
            db=database, device_id=seed_device(database.conn), tmp_path=tmp_path
        )
