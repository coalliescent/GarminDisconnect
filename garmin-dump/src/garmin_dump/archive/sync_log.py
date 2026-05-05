"""High-level sync_log helpers used by the pull/prune commands.

This module sits between the raw `db.repo` insert/update functions and the
orchestration code in `commands/pull.py`. It exists so the algorithm in `pull.py` reads
top-down without inline SQL.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from garmin_dump.archive.layout import Category
from garmin_dump.db import repo


@dataclass(frozen=True)
class RemoteFileSpec:
    """Just enough to identify a file on the device for sync purposes."""

    parent_path: str          # e.g. "/GARMIN/Activity"
    filename: str             # e.g. "2026-04-07-08-13-22.fit"
    size_bytes: int
    file_id: int              # unstable across reconnects; valid only within one session
    category: Category


def begin_pending(
    conn: sqlite3.Connection,
    device_id: int,
    spec: RemoteFileSpec,
) -> int:
    """Idempotently mark a file as pending and return its sync_id."""
    return repo.upsert_sync_pending(
        conn,
        repo.SyncKey(
            device_id=device_id,
            remote_parent=spec.parent_path,
            filename=spec.filename,
            size_bytes=spec.size_bytes,
        ),
        category=str(spec.category),
    )


def lookup(
    conn: sqlite3.Connection,
    device_id: int,
    spec: RemoteFileSpec,
) -> sqlite3.Row | None:
    return repo.find_sync_row(
        conn,
        repo.SyncKey(
            device_id=device_id,
            remote_parent=spec.parent_path,
            filename=spec.filename,
            size_bytes=spec.size_bytes,
        ),
    )


def needs_download(row: sqlite3.Row | None) -> bool:
    """Decide whether a file should be (re)fetched.

    Already-synced rows in `verified`, `downloaded`, or `deleted_remote` are skipped.
    `pending` and `failed` are retried.
    """
    if row is None:
        return True
    status = row["status"]
    return status in ("pending", "failed")


def detect_remote_deletions(
    conn: sqlite3.Connection,
    device_id: int,
    seen_keys: set[tuple[str, str, int]],
) -> int:
    """Mark sync_log rows as deleted_remote if they weren't seen this run.

    `seen_keys` is the set of `(remote_parent, filename, size_bytes)` tuples observed in
    the current inventory. Returns the number of rows transitioned.
    """
    rows = repo.list_active_sync_rows_for_device(conn, device_id)
    n = 0
    for r in rows:
        key = (r["remote_parent"], r["filename"], int(r["size_bytes"]))
        if key not in seen_keys:
            repo.mark_sync_deleted_remote(conn, int(r["sync_id"]))
            n += 1
    return n


# ---------- prune helpers ---------------------------------------------------------------


def cutoff_iso(retention_days: int) -> str:
    """ISO-8601 string for `now - retention_days`."""
    cutoff = datetime.now(tz=UTC) - timedelta(days=retention_days)
    return cutoff.replace(microsecond=0).isoformat()


def list_prune_candidates(
    conn: sqlite3.Connection,
    *,
    device_id: int,
    retention_days: int,
    category: str | None = None,
) -> list[sqlite3.Row]:
    """Return verified sync_log rows older than `retention_days`.

    Caller must re-hash the local copy before deletion (see `commands/prune.py`).
    """
    return repo.list_verified_sync_rows(
        conn,
        device_id=device_id,
        category=category,
        older_than_iso=cutoff_iso(retention_days),
    )
