"""`garmin-dump ingest` — local-only re-parse of FIT files into SQLite.

No device required. Walks `sync_log` rows in `verified` status (optionally filtered by
scope or first_seen date), reads each FIT file from the archive, and re-runs the
ingest pipeline. With `--reparse`, existing parsed rows are deleted via FK CASCADE
before re-insertion.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
)

from garmin_dump.archive.layout import Category
from garmin_dump.config import Config
from garmin_dump.db import repo
from garmin_dump.db.connection import Database
from garmin_dump.ingest.dispatcher import ingest_file
from garmin_dump.logging_setup import get_logger

log = get_logger()


@dataclass
class IngestOptions:
    reparse: bool = False
    since: str | None = None  # ISO date "YYYY-MM-DD"
    scope: frozenset[Category] | None = None


def run_ingest(
    cfg: Config,
    opts: IngestOptions,
    *,
    argv: list[str],
    console: Console | None = None,
) -> int:
    console = console or Console()
    with Database(cfg.db_path) as db:
        run = repo.start_run(db.conn, subcommand="ingest", argv=argv)

        # Build the row set
        rows = _select_rows(db, opts)
        if not rows:
            console.print("[yellow]no verified files match the filter; nothing to do.[/yellow]")
            repo.finish_run(db.conn, run.run_id, exit_code=0)
            return 0

        if opts.reparse:
            for row in rows:
                _purge_existing(db, row)

        seen = 0
        ok = 0
        errors = 0
        with _make_progress(console) as progress:
            task = progress.add_task("ingesting", total=len(rows))
            for row in rows:
                seen += 1
                local_rel = row["local_path"]
                if not local_rel:
                    progress.advance(task)
                    continue
                local = cfg.archive_root / local_rel
                if not local.is_file():
                    log.warning("missing local file for sync_id=%s: %s", row["sync_id"], local)
                    repo.mark_sync_parser_error(
                        db.conn, int(row["sync_id"]), parser_error=f"missing file {local}"
                    )
                    errors += 1
                    progress.advance(task)
                    continue
                category = Category(row["category"]) if row["category"] in [c.value for c in Category] else Category.OTHER
                ir = ingest_file(
                    db.conn,
                    sync_id=int(row["sync_id"]),
                    device_id=int(row["device_id"]),
                    file_sha256=str(row["sha256"] or ""),
                    path=local,
                    category_hint=category,
                )
                if ir.error is not None:
                    errors += 1
                else:
                    ok += 1
                progress.advance(task)

        console.print(
            f"[green]ingest done.[/green] processed {seen} files, {ok} ok, {errors} errors."
        )
        repo.finish_run(
            db.conn, run.run_id,
            files_seen=seen,
            errors_count=errors,
            exit_code=0 if errors == 0 else 1,
        )
        return 0 if errors == 0 else 1


def _select_rows(db: Database, opts: IngestOptions):
    sql = "SELECT * FROM sync_log WHERE status = 'verified'"
    params: list[object] = []
    if opts.since:
        sql += " AND first_seen_utc >= ?"
        params.append(opts.since)
    if opts.scope:
        placeholders = ",".join("?" for _ in opts.scope)
        sql += f" AND category IN ({placeholders})"
        params.extend([str(c) for c in opts.scope])
    sql += " ORDER BY first_seen_utc"
    return db.conn.execute(sql, params).fetchall()


def _purge_existing(db: Database, row) -> None:
    """Delete previously-parsed rows for this sync_id so a reparse is clean."""
    sync_id = int(row["sync_id"])
    sha = row["sha256"]
    device_id = int(row["device_id"])
    if not sha:
        return
    db.conn.execute(
        "DELETE FROM activities WHERE device_id = ? AND file_sha256 = ?",
        (device_id, sha),
    )
    db.conn.execute("DELETE FROM unknown_fit_messages WHERE sync_id = ?", (sync_id,))
    db.conn.execute("DELETE FROM wellness_samples WHERE sync_id = ?", (sync_id,))
    # sleep_sessions and sleep_stages: cascade-delete via FK on sleep_id, but
    # we have to delete sleep_sessions explicitly because its sync_id FK is
    # ON DELETE SET NULL (not CASCADE) — we'd otherwise leave stale rows
    # whenever the parser's start_utc derivation changes between runs.
    db.conn.execute(
        "DELETE FROM sleep_sessions WHERE device_id = ? AND sync_id = ?",
        (device_id, sync_id),
    )
    # wellness_daily uses upsert keyed by (device_id, date_local) — its rows
    # accumulate across files for the same day, so we don't pre-delete here.


def _make_progress(console: Console) -> Progress:
    return Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeElapsedColumn(),
        console=console,
    )


_ = Path
