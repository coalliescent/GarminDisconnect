"""Tests for the monitoring FIT parser's named-by-num pass.

Verifies that ingest_monitoring against an Instinct 3-shaped monitor file
populates `wellness_samples` with the named messages we now decode
(stress_level from g=227, respiration_rate from g=297) and that the daily
rollup picks them up so wellness_daily.avg_stress / respiration_avg are
non-NULL.

The fixture is SYNTHETIC — see tests/fixtures/build_fit_fixtures.py. Structure
is faithful; values are invented. Not ground truth for field semantics.
"""

from __future__ import annotations

from pathlib import Path

from garmin_dump.db.connection import Database
from garmin_dump.db.repo import (
    DeviceUpsert,
    SyncKey,
    mark_sync_verified,
    upsert_device,
    upsert_sync_pending,
)
from garmin_dump.ingest.monitoring import ingest_monitoring

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
MONITOR_FIXTURE = FIXTURES / "monitor_M47N0648.FIT"  # 120 stress + 120 respiration samples


def _seed(db: Database) -> tuple[int, int]:
    device_id = upsert_device(
        db.conn,
        DeviceUpsert(
            serial="3509067685",
            unit_id="test_unit",
            part_number=None,
            model="Instinct 3",
            software_version="521",
        ),
    )
    sync_id = upsert_sync_pending(
        db.conn,
        SyncKey(
            device_id=device_id,
            remote_parent="Monitor",
            filename="monitor_M47N0648.FIT",
            size_bytes=MONITOR_FIXTURE.stat().st_size,
        ),
        category="monitor",
    )
    mark_sync_verified(db.conn, sync_id, sha256="0" * 64, local_path=str(MONITOR_FIXTURE))
    return device_id, sync_id


def test_ingest_monitoring_emits_stress_samples(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        device_id, sync_id = _seed(db)
        n = ingest_monitoring(
            db.conn, sync_id=sync_id, device_id=device_id, path=MONITOR_FIXTURE
        )
        assert n > 0

        rows = db.conn.execute(
            "SELECT value FROM wellness_samples WHERE metric = 'stress_level'"
        ).fetchall()
        assert len(rows) > 0, "no stress_level samples written"
        for row in rows:
            assert 0 <= row["value"] <= 100, f"stress out of range: {row['value']}"


def test_ingest_monitoring_emits_respiration_samples(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        device_id, sync_id = _seed(db)
        ingest_monitoring(
            db.conn, sync_id=sync_id, device_id=device_id, path=MONITOR_FIXTURE
        )

        rows = db.conn.execute(
            "SELECT value, unit FROM wellness_samples WHERE metric = 'respiration_rate'"
        ).fetchall()
        assert len(rows) > 0, "no respiration_rate samples written"
        for row in rows:
            # Sanity-check the scale=100 conversion: human respiration is 5–30 br/min.
            assert 5 <= row["value"] <= 30, f"respiration out of range: {row['value']}"
            assert row["unit"] == "breaths/min"


def test_ingest_monitoring_populates_daily_rollup(tmp_path: Path) -> None:
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        device_id, sync_id = _seed(db)
        ingest_monitoring(
            db.conn, sync_id=sync_id, device_id=device_id, path=MONITOR_FIXTURE
        )

        rows = db.conn.execute(
            """
            SELECT date_local, avg_stress, respiration_avg
            FROM wellness_daily
            """
        ).fetchall()
        assert len(rows) > 0, "no wellness_daily rows written"
        # At least one day should have non-NULL avg_stress and respiration_avg
        # — those are the columns the GarminDisconnect viewer reads.
        any_stress = any(r["avg_stress"] is not None for r in rows)
        any_resp = any(r["respiration_avg"] is not None for r in rows)
        assert any_stress, "wellness_daily.avg_stress is NULL on every row"
        assert any_resp, "wellness_daily.respiration_avg is NULL on every row"


def test_ingest_monitoring_stashes_forensic_f2(tmp_path: Path) -> None:
    """The unsolved companion field on stress_level (227.f2) is stored as
    `monitor_stress_f2` so the user can mine it later from SQL."""
    db_path = tmp_path / "test.db"
    with Database(db_path) as db:
        device_id, sync_id = _seed(db)
        ingest_monitoring(
            db.conn, sync_id=sync_id, device_id=device_id, path=MONITOR_FIXTURE
        )

        rows = db.conn.execute(
            "SELECT value FROM wellness_samples WHERE metric = 'monitor_stress_f2'"
        ).fetchall()
        # The fixture is small but we know it has stress_level messages, and
        # f2 is dense (always populated). So we should see some f2 rows.
        assert len(rows) > 0
        for row in rows:
            assert -100 < row["value"] < 110
