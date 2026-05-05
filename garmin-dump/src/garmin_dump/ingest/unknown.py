"""Persist counts + samples of `unknown_NNN` FIT messages.

Garmin emits a lot of undocumented messages, especially in sleep and metrics files.
We don't try to interpret them — we just record their existence so a future parser
pass can target the highest-volume unknowns first.
"""

from __future__ import annotations

import sqlite3

from garmin_dump.db.repo import json_dumps_safe
from garmin_dump.ingest.fit_reader import MessageBuckets


def record_unknowns(conn: sqlite3.Connection, sync_id: int, buckets: MessageBuckets) -> None:
    """Insert one row per unknown message number found in this file."""
    for msg_num, count in buckets.unknown_counts.items():
        sample = buckets.unknown_samples.get(msg_num, {})
        conn.execute(
            """
            INSERT INTO unknown_fit_messages (sync_id, msg_num, occurrence_count, sample_json)
            VALUES (?, ?, ?, ?)
            """,
            (sync_id, msg_num, count, json_dumps_safe(sample)),
        )
