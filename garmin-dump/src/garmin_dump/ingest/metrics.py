"""Metrics FIT file ingestion (best-effort).

Metrics files (`MetricsFileFor_*.fit`) hold periodic training-status snapshots:
training load, FTP estimates, race predictions, VO2 max, HRV summary. Their message
catalog is firmware-specific. For v1 we punt on a dedicated metrics table — the most
useful fields (resting/avg HR, VO2, HRV, body battery) get folded into `wellness_daily`
and the raw FIT file is preserved on disk.

This module exists so the `ingest.py` dispatcher has somewhere to call. It's a no-op
beyond `unknown_fit_messages` recording today; future work can promote recognized
fields into a `metrics_daily` table.
"""

from __future__ import annotations

import sqlite3

from garmin_dump.ingest.fit_reader import MessageBuckets


def ingest_metrics(
    conn: sqlite3.Connection,
    *,
    sync_id: int,
    device_id: int,
    buckets: MessageBuckets,
) -> None:
    """Best-effort metrics ingest. Currently a no-op beyond unknown_NNN tracking."""
    # Reserved for future expansion. The unknowns are recorded by the caller via
    # `record_unknowns(conn, sync_id, buckets)`.
    _ = conn, sync_id, device_id, buckets
