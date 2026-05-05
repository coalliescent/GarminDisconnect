"""Top-level FIT ingestion dispatcher.

Given a FIT file path, decide which per-category ingest function to call. The FIT
`file_id.type` is authoritative — the directory the file came from is just a hint.
We fall back to category hints when the FIT header doesn't tell us anything useful.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from garmin_dump.archive.layout import Category
from garmin_dump.db import repo
from garmin_dump.ingest.activity import ingest_activity
from garmin_dump.ingest.fit_reader import bucket_file, peek_file_type
from garmin_dump.ingest.metrics import ingest_metrics
from garmin_dump.ingest.monitoring import ingest_monitoring
from garmin_dump.ingest.sleep import ingest_sleep
from garmin_dump.ingest.unknown import record_unknowns
from garmin_dump.logging_setup import get_logger

log = get_logger()


@dataclass(frozen=True)
class IngestResult:
    """What happened when we tried to ingest a single file."""

    fit_type: str | None
    activity_id: int | None = None
    sleep_id: int | None = None
    sample_count: int = 0
    error: str | None = None


# Mapping from FIT file_id.type → high-level handler.
_HANDLERS: dict[str, Callable[..., None]] = {}  # populated below


def ingest_file(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    file_sha256: str,
    path: Path,
    category_hint: Category,
) -> IngestResult:
    """Parse `path` and route it to the appropriate ingest handler.

    Returns an IngestResult. Per-file errors are logged + recorded on sync_log.parser_error
    rather than raised, so a single bad file doesn't abort a whole batch.
    """
    try:
        fit_type = peek_file_type(path)
    except Exception as e:
        log.warning("could not peek file type for %s: %s", path, e)
        repo.mark_sync_parser_error(conn, sync_id, parser_error=f"peek failed: {e}")
        return IngestResult(fit_type=None, error=str(e))

    handler_key = (fit_type or "").lower() or _category_to_fit_type(category_hint)

    try:
        # `hrv_status` files (newer fw, file_id.type=68) live in the Monitor
        # directory and contain only HRV messages (g=370/371). Routing them
        # through the monitoring handler lets the named-by-num pass extract
        # hrv_value samples without a dedicated handler.
        if handler_key.startswith("monitoring") or handler_key == "hrv_status":
            return _ingest_monitoring(
                conn, sync_id=sync_id, device_id=device_id, path=path, fit_type=fit_type
            )
        # Activity, sleep, metrics, and unknown all want bucketed messages.
        buckets = bucket_file(path)
        record_unknowns(conn, sync_id, buckets)

        if handler_key == "activity":
            activity_id = ingest_activity(
                conn,
                sync_id=sync_id,
                device_id=device_id,
                file_sha256=file_sha256,
                buckets=buckets,
            )
            return IngestResult(fit_type=fit_type, activity_id=activity_id)
        if handler_key == "sleep":
            sleep_id = ingest_sleep(
                conn, sync_id=sync_id, device_id=device_id, buckets=buckets
            )
            return IngestResult(fit_type=fit_type, sleep_id=sleep_id)
        if handler_key in ("metrics", "metric"):
            ingest_metrics(conn, sync_id=sync_id, device_id=device_id, buckets=buckets)
            return IngestResult(fit_type=fit_type)
        # Anything else: we already recorded unknowns, nothing more to do.
        return IngestResult(fit_type=fit_type)
    except Exception as e:
        log.warning("ingest failed for %s: %s", path, e)
        repo.mark_sync_parser_error(conn, sync_id, parser_error=str(e))
        return IngestResult(fit_type=None, error=str(e))


def _ingest_monitoring(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    path: Path,
    fit_type: str | None,
) -> IngestResult:
    """Streaming ingest for monitoring files (don't bucket — they can be huge)."""
    sample_count = ingest_monitoring(
        conn, sync_id=sync_id, device_id=device_id, path=path
    )
    # Monitoring files have unknown messages too — re-bucket cheaply for the catch-all.
    # We can do this because monitoring files are still small enough to fit in memory
    # for any practical sync window.
    try:
        buckets = bucket_file(path)
        record_unknowns(conn, sync_id, buckets)
    except Exception as e:
        log.debug("could not record unknowns for monitoring %s: %s", path, e)
    return IngestResult(fit_type=fit_type, sample_count=sample_count)


def _category_to_fit_type(cat: Category) -> str:
    """Fallback FIT type when the file_id message isn't available."""
    return {
        Category.ACTIVITY: "activity",
        Category.MONITOR: "monitoring",
        Category.SLEEP: "sleep",
        Category.METRICS: "metrics",
        Category.OTHER: "",
    }[cat]


# silence unused
_ = _HANDLERS
