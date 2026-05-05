"""Tests for the sync_log idempotency layer."""

from __future__ import annotations

from pathlib import Path

from garmin_dump.archive.layout import Category
from garmin_dump.archive.sync_log import (
    RemoteFileSpec,
    begin_pending,
    detect_remote_deletions,
    lookup,
    needs_download,
)
from garmin_dump.db import repo
from garmin_dump.db.connection import Database


def _setup(tmp_path: Path) -> tuple[Database, int]:
    db = Database(tmp_path / "test.db")
    db.open()
    device_id = repo.upsert_device(
        db.conn,
        repo.DeviceUpsert(
            serial="ABC123",
            unit_id="ABC123",
            part_number="P/N",
            model="Test",
            software_version="1.0",
        ),
    )
    return db, device_id


def _spec(filename: str = "x.fit") -> RemoteFileSpec:
    return RemoteFileSpec(
        parent_path="/GARMIN/Activity",
        filename=filename,
        size_bytes=1234,
        file_id=42,
        category=Category.ACTIVITY,
    )


def test_first_seen_creates_pending(tmp_path: Path) -> None:
    db, device_id = _setup(tmp_path)
    spec = _spec()
    sync_id = begin_pending(db.conn, device_id, spec)
    row = lookup(db.conn, device_id, spec)
    assert row is not None
    assert row["sync_id"] == sync_id
    assert row["status"] == "pending"
    assert needs_download(row) is True


def test_verified_row_does_not_need_download(tmp_path: Path) -> None:
    db, device_id = _setup(tmp_path)
    spec = _spec()
    sync_id = begin_pending(db.conn, device_id, spec)
    repo.mark_sync_verified(
        db.conn,
        sync_id,
        sha256="0" * 64,
        local_path="devices/ABC123/Activity/x.fit",
    )
    row = lookup(db.conn, device_id, spec)
    assert row is not None
    assert row["status"] == "verified"
    assert needs_download(row) is False


def test_failed_row_needs_retry(tmp_path: Path) -> None:
    db, device_id = _setup(tmp_path)
    spec = _spec()
    sync_id = begin_pending(db.conn, device_id, spec)
    repo.mark_sync_failed(db.conn, sync_id, error_message="boom")
    row = lookup(db.conn, device_id, spec)
    assert row is not None
    assert row["status"] == "failed"
    assert needs_download(row) is True


def test_detect_remote_deletions_marks_missing(tmp_path: Path) -> None:
    db, device_id = _setup(tmp_path)
    spec1 = _spec("a.fit")
    spec2 = _spec("b.fit")
    s1 = begin_pending(db.conn, device_id, spec1)
    s2 = begin_pending(db.conn, device_id, spec2)
    repo.mark_sync_verified(db.conn, s1, sha256="1" * 64, local_path="a")
    repo.mark_sync_verified(db.conn, s2, sha256="2" * 64, local_path="b")

    # Only spec1 still on device.
    seen = {(spec1.parent_path, spec1.filename, spec1.size_bytes)}
    n = detect_remote_deletions(db.conn, device_id, seen)
    assert n == 1
    row2 = lookup(db.conn, device_id, spec2)
    assert row2 is not None
    assert row2["status"] == "deleted_remote"


def test_dedup_key_unique(tmp_path: Path) -> None:
    db, device_id = _setup(tmp_path)
    spec = _spec()
    s1 = begin_pending(db.conn, device_id, spec)
    s2 = begin_pending(db.conn, device_id, spec)
    assert s1 == s2  # idempotent
