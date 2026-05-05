"""`garmin-dump info {device|archive|db}` — local-only diagnostics.

No device required. Prints summaries of cached state for the user, and is the canonical
way to find the SQLite database path so users can run their own `sqlite3` queries.
"""

from __future__ import annotations

import json
from pathlib import Path

from rich.console import Console
from rich.table import Table

from garmin_dump.config import Config
from garmin_dump.db.connection import Database
from garmin_dump.db.migrations import CURRENT_VERSION, get_user_version


def run_info_db(cfg: Config, *, console: Console | None = None) -> int:
    console = console or Console()
    if not cfg.db_path.exists():
        console.print(f"[yellow]no database yet at {cfg.db_path}[/yellow]")
        console.print("Run `garmin-dump pull` (or `garmin-dump doctor`) to create it.")
        return 0
    with Database(cfg.db_path) as db:
        version = get_user_version(db.conn)
        size_bytes = cfg.db_path.stat().st_size
        tables = [
            "devices", "sync_log", "activities", "activity_laps", "activity_records",
            "wellness_daily", "wellness_samples", "sleep_sessions", "sleep_stages",
            "unknown_fit_messages", "runs",
        ]
        table = Table(title=f"database — {cfg.db_path}", show_header=True, header_style="bold")
        table.add_column("table")
        table.add_column("rows", justify="right")
        for t in tables:
            try:
                count = db.conn.execute(f"SELECT COUNT(*) AS c FROM {t}").fetchone()["c"]
            except Exception:
                count = "?"
            table.add_row(t, str(count))
        console.print(
            f"schema version: [bold]{version}[/bold] (latest known: {CURRENT_VERSION})  "
            f"file size: {size_bytes / 1024:.1f} KiB"
        )
        console.print(table)
        console.print(
            f"[dim]query directly with:[/dim] sqlite3 {cfg.db_path}"
        )
    return 0


def run_info_device(cfg: Config, *, console: Console | None = None) -> int:
    console = console or Console()
    if not cfg.devices_dir.exists():
        console.print("[yellow]no devices known yet.[/yellow] Run `garmin-dump pull`.")
        return 0
    found = 0
    for serial_dir in sorted(cfg.devices_dir.iterdir()):
        if not serial_dir.is_dir():
            continue
        json_path = serial_dir / "device.json"
        if not json_path.is_file():
            continue
        info = json.loads(json_path.read_text(encoding="utf-8"))
        console.print(f"[bold]{serial_dir.name}[/bold]")
        for k in ("model", "part_number", "software_version", "unit_id", "serial"):
            v = info.get(k)
            if v:
                console.print(f"  {k}: {v}")
        found += 1
    if found == 0:
        console.print("[yellow]no devices known yet.[/yellow] Run `garmin-dump pull`.")
    return 0


def run_info_archive(cfg: Config, *, console: Console | None = None) -> int:
    console = console or Console()
    if not cfg.devices_dir.exists():
        console.print("[yellow]no archive yet.[/yellow]")
        return 0
    table = Table(title=f"archive — {cfg.archive_root}", show_header=True, header_style="bold")
    table.add_column("device")
    table.add_column("category")
    table.add_column("files", justify="right")
    table.add_column("MB", justify="right")
    grand_files = 0
    grand_bytes = 0
    for serial_dir in sorted(cfg.devices_dir.iterdir()):
        if not serial_dir.is_dir():
            continue
        for cat_dir in sorted(serial_dir.iterdir()):
            if not cat_dir.is_dir():
                continue
            files, size = _walk(cat_dir)
            if files == 0:
                continue
            table.add_row(
                serial_dir.name, cat_dir.name, str(files), f"{size / 1e6:.2f}"
            )
            grand_files += files
            grand_bytes += size
    table.add_row("[bold]total[/bold]", "", f"[bold]{grand_files}[/bold]", f"[bold]{grand_bytes / 1e6:.2f}[/bold]")
    console.print(table)
    return 0


def _walk(root: Path) -> tuple[int, int]:
    files = 0
    size = 0
    for p in root.rglob("*"):
        if p.is_file():
            files += 1
            try:
                size += p.stat().st_size
            except OSError:
                pass
    return files, size
