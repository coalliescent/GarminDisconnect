"""`garmin-dump export` — convenience CSV/JSON/JSONL dumper.

Lets users get rows out without learning the schema. Anything more involved should be a
direct `sqlite3` query against `cfg.db_path`.
"""

from __future__ import annotations

import csv
import json
import sys
from collections.abc import Iterable
from typing import TextIO

from rich.console import Console

from garmin_dump.config import Config
from garmin_dump.db.connection import Database

EXPORTABLE_TABLES = (
    "devices",
    "sync_log",
    "activities",
    "activity_laps",
    "activity_records",
    "wellness_daily",
    "wellness_samples",
    "sleep_sessions",
    "sleep_stages",
    "unknown_fit_messages",
    "runs",
)

# Per-table time column used for --since / --until filtering. Tables not in the map
# don't support time filters.
TIME_COLUMN: dict[str, str] = {
    "activities": "start_time_utc",
    "activity_records": "timestamp_utc",
    "wellness_daily": "date_local",
    "wellness_samples": "timestamp_utc",
    "sleep_sessions": "start_utc",
    "sleep_stages": "start_utc",
    "sync_log": "first_seen_utc",
    "runs": "started_utc",
}


def run_export(
    cfg: Config,
    *,
    table: str,
    fmt: str,
    since: str | None,
    until: str | None,
    out: TextIO | None = None,
    console: Console | None = None,
) -> int:
    console = console or Console()
    out = out or sys.stdout
    if table not in EXPORTABLE_TABLES:
        console.print(
            f"[red]error:[/red] unknown table {table!r}. "
            f"Choose one of: {', '.join(EXPORTABLE_TABLES)}"
        )
        return 2
    if fmt not in ("csv", "json", "jsonl"):
        console.print(f"[red]error:[/red] format must be csv|json|jsonl, got {fmt!r}")
        return 2

    with Database(cfg.db_path) as db:
        sql = f"SELECT * FROM {table}"
        params: list[object] = []
        clauses: list[str] = []
        time_col = TIME_COLUMN.get(table)
        if since and time_col:
            clauses.append(f"{time_col} >= ?")
            params.append(since)
        if until and time_col:
            clauses.append(f"{time_col} < ?")
            params.append(until)
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        rows = db.conn.execute(sql, params).fetchall()
        if not rows:
            console.print("[yellow]no rows.[/yellow]", file=sys.stderr)
            return 0
        cols = rows[0].keys()
        if fmt == "csv":
            _write_csv(out, cols, rows)
        elif fmt == "jsonl":
            _write_jsonl(out, cols, rows)
        else:
            _write_json(out, cols, rows)
    return 0


def _write_csv(out: TextIO, cols: list[str], rows: Iterable) -> None:
    writer = csv.writer(out)
    writer.writerow(cols)
    for r in rows:
        writer.writerow([r[c] for c in cols])


def _write_jsonl(out: TextIO, cols: list[str], rows: Iterable) -> None:
    for r in rows:
        out.write(json.dumps({c: r[c] for c in cols}, default=str))
        out.write("\n")


def _write_json(out: TextIO, cols: list[str], rows: Iterable) -> None:
    json.dump([{c: r[c] for c in cols} for r in rows], out, default=str, indent=2)
    out.write("\n")
