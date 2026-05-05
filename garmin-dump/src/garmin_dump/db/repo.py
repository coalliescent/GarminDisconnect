"""Typed insert/upsert helpers.

This is a thin layer over `sqlite3.Connection` — not an ORM. The point is to keep SQL out
of command/orchestration code, and to give callers dataclasses for arguments instead of
positional tuples.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import asdict, dataclass
from datetime import UTC, datetime


def utc_now_iso() -> str:
    """Current time as an ISO-8601 UTC string with second precision."""
    return datetime.now(tz=UTC).replace(microsecond=0).isoformat()


# ---------- devices ---------------------------------------------------------------------


@dataclass(frozen=True)
class DeviceUpsert:
    serial: str
    unit_id: str | None
    part_number: str | None
    model: str | None
    software_version: str | None


def upsert_device(conn: sqlite3.Connection, info: DeviceUpsert) -> int:
    """Upsert a device by serial; return its device_id."""
    now = utc_now_iso()
    conn.execute(
        """
        INSERT INTO devices (
            serial, unit_id, part_number, model, software_version,
            first_seen_utc, last_seen_utc
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(serial) DO UPDATE SET
            unit_id          = COALESCE(excluded.unit_id, devices.unit_id),
            part_number      = COALESCE(excluded.part_number, devices.part_number),
            model            = COALESCE(excluded.model, devices.model),
            software_version = COALESCE(excluded.software_version, devices.software_version),
            last_seen_utc    = excluded.last_seen_utc
        """,
        (
            info.serial,
            info.unit_id,
            info.part_number,
            info.model,
            info.software_version,
            now,
            now,
        ),
    )
    row = conn.execute(
        "SELECT device_id FROM devices WHERE serial = ?",
        (info.serial,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"device upsert failed for serial {info.serial!r}")
    return int(row["device_id"])


def get_device_by_serial(conn: sqlite3.Connection, serial: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM devices WHERE serial = ?", (serial,)
    ).fetchone()


# ---------- sync_log --------------------------------------------------------------------


SYNC_STATUSES = frozenset(
    {"pending", "downloaded", "verified", "failed", "deleted_remote"}
)


@dataclass(frozen=True)
class SyncKey:
    device_id: int
    remote_parent: str
    filename: str
    size_bytes: int


def find_sync_row(conn: sqlite3.Connection, key: SyncKey) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT * FROM sync_log
        WHERE device_id = ? AND remote_parent = ? AND filename = ? AND size_bytes = ?
        """,
        (key.device_id, key.remote_parent, key.filename, key.size_bytes),
    ).fetchone()


def upsert_sync_pending(
    conn: sqlite3.Connection,
    key: SyncKey,
    *,
    category: str,
) -> int:
    """Insert a `pending` sync_log row, or no-op if one exists. Returns sync_id."""
    now = utc_now_iso()
    conn.execute(
        """
        INSERT INTO sync_log (
            device_id, remote_parent, filename, size_bytes,
            category, status, first_seen_utc
        )
        VALUES (?, ?, ?, ?, ?, 'pending', ?)
        ON CONFLICT(device_id, remote_parent, filename, size_bytes) DO NOTHING
        """,
        (key.device_id, key.remote_parent, key.filename, key.size_bytes, category, now),
    )
    row = find_sync_row(conn, key)
    if row is None:
        raise RuntimeError(f"sync_log upsert failed for {key}")
    return int(row["sync_id"])


def mark_sync_verified(
    conn: sqlite3.Connection,
    sync_id: int,
    *,
    sha256: str,
    local_path: str,
) -> None:
    now = utc_now_iso()
    conn.execute(
        """
        UPDATE sync_log
        SET status = 'verified',
            sha256 = ?,
            local_path = ?,
            downloaded_utc = COALESCE(downloaded_utc, ?),
            verified_utc = ?,
            error_message = NULL
        WHERE sync_id = ?
        """,
        (sha256, local_path, now, now, sync_id),
    )


def mark_sync_failed(
    conn: sqlite3.Connection,
    sync_id: int,
    *,
    error_message: str,
) -> None:
    conn.execute(
        "UPDATE sync_log SET status = 'failed', error_message = ? WHERE sync_id = ?",
        (error_message, sync_id),
    )


def mark_sync_deleted_remote(conn: sqlite3.Connection, sync_id: int) -> None:
    now = utc_now_iso()
    conn.execute(
        """
        UPDATE sync_log
        SET status = 'deleted_remote', deleted_remote_utc = ?
        WHERE sync_id = ?
        """,
        (now, sync_id),
    )


def mark_sync_parser_error(
    conn: sqlite3.Connection,
    sync_id: int,
    *,
    parser_error: str,
) -> None:
    conn.execute(
        "UPDATE sync_log SET parser_error = ? WHERE sync_id = ?",
        (parser_error, sync_id),
    )


def list_verified_sync_rows(
    conn: sqlite3.Connection,
    *,
    device_id: int | None = None,
    category: str | None = None,
    older_than_iso: str | None = None,
) -> list[sqlite3.Row]:
    """List sync_log rows currently in `verified` status, with optional filters."""
    clauses = ["status = 'verified'"]
    params: list[object] = []
    if device_id is not None:
        clauses.append("device_id = ?")
        params.append(device_id)
    if category is not None:
        clauses.append("category = ?")
        params.append(category)
    if older_than_iso is not None:
        clauses.append("first_seen_utc < ?")
        params.append(older_than_iso)
    sql = f"SELECT * FROM sync_log WHERE {' AND '.join(clauses)} ORDER BY first_seen_utc"
    return conn.execute(sql, params).fetchall()


def list_active_sync_rows_for_device(
    conn: sqlite3.Connection, device_id: int
) -> list[sqlite3.Row]:
    """List rows that are still considered to live on the device.

    Used by the deletion-detection step in `pull` to mark files that vanished from the
    device since last sync.
    """
    return conn.execute(
        """
        SELECT * FROM sync_log
        WHERE device_id = ? AND status IN ('verified', 'downloaded')
        """,
        (device_id,),
    ).fetchall()


# ---------- runs ------------------------------------------------------------------------


@dataclass
class RunRecord:
    run_id: int
    started_utc: str


def start_run(
    conn: sqlite3.Connection,
    *,
    subcommand: str,
    argv: list[str],
    device_id: int | None = None,
) -> RunRecord:
    started = utc_now_iso()
    cur = conn.execute(
        """
        INSERT INTO runs (started_utc, subcommand, argv_json, device_id)
        VALUES (?, ?, ?, ?)
        """,
        (started, subcommand, json.dumps(argv), device_id),
    )
    return RunRecord(run_id=int(cur.lastrowid or 0), started_utc=started)


def finish_run(
    conn: sqlite3.Connection,
    run_id: int,
    *,
    files_seen: int = 0,
    files_downloaded: int = 0,
    bytes_downloaded: int = 0,
    files_deleted: int = 0,
    errors_count: int = 0,
    exit_code: int = 0,
    device_id: int | None = None,
) -> None:
    conn.execute(
        """
        UPDATE runs SET
            finished_utc = ?,
            files_seen = ?,
            files_downloaded = ?,
            bytes_downloaded = ?,
            files_deleted = ?,
            errors_count = ?,
            exit_code = ?,
            device_id = COALESCE(?, device_id)
        WHERE run_id = ?
        """,
        (
            utc_now_iso(),
            files_seen,
            files_downloaded,
            bytes_downloaded,
            files_deleted,
            errors_count,
            exit_code,
            device_id,
            run_id,
        ),
    )


# ---------- json helper -----------------------------------------------------------------


def json_dumps_safe(obj: object) -> str:
    """JSON dump that survives datetimes, bytes, and other awkward FIT field types."""
    return json.dumps(obj, default=str, separators=(",", ":"))


# Silence linter for unused asdict import. Reserved for future row→dataclass helpers.
_ = asdict
