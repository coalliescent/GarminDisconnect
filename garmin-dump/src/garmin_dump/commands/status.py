"""`garmin-dump status` — what would `pull` do right now?

This is the read-only sibling of `pull --dry-run`. It still requires the device to be
plugged in (and Garmin Express to be quit). It does NOT mutate the database — well,
strictly: it doesn't transition any sync_log row state.
"""

from __future__ import annotations

from rich.console import Console
from rich.table import Table

from garmin_dump.archive.layout import Category, DeviceArchive
from garmin_dump.archive.sync_log import RemoteFileSpec, lookup, needs_download
from garmin_dump.commands.pull import (
    ALL_CATEGORIES,
    DEFAULT_CATEGORIES,
    _read_device_xml,
    _select_specs,
)
from garmin_dump.config import Config, ensure_dirs
from garmin_dump.db import repo
from garmin_dump.db.connection import Database
from garmin_dump.errors import (
    GarminDumpError,
    MtpOutputParseError,
)
from garmin_dump.mtp.detect import detect_garmin
from garmin_dump.mtp.inventory import fetch_inventory
from garmin_dump.mtp.runner import MtpRunner
from garmin_dump.mtp.trash import find_trash, total_bytes


def run_status(
    cfg: Config,
    *,
    full: bool = False,
    console: Console | None = None,
) -> int:
    console = console or Console()
    ensure_dirs(cfg)
    runner = MtpRunner()

    try:
        runner.assert_libmtp_supported()
        detect_garmin(runner)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2

    try:
        inventory, _, _ = fetch_inventory(runner)
    except MtpOutputParseError as e:
        console.print(f"[red]error:[/red] failed to parse {e.tool} output: {e}")
        return 2

    try:
        info = _read_device_xml(runner, inventory, cfg.tmp_dir)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2

    serial = info.archive_serial
    archive = DeviceArchive(cfg.archive_root, serial)

    scope = ALL_CATEGORIES if full else DEFAULT_CATEGORIES
    specs = _select_specs(inventory, scope)
    trash = find_trash(inventory)

    with Database(cfg.db_path) as db:
        device_row = repo.get_device_by_serial(db.conn, serial)
        device_id = int(device_row["device_id"]) if device_row is not None else None

        new_count: dict[Category, int] = {c: 0 for c in scope}
        new_bytes: dict[Category, int] = {c: 0 for c in scope}
        existing_count: dict[Category, int] = {c: 0 for c in scope}
        for spec in specs:
            row = None
            if device_id is not None:
                row = lookup(db.conn, device_id, spec)
            if needs_download(row):
                new_count[spec.category] = new_count.get(spec.category, 0) + 1
                new_bytes[spec.category] = new_bytes.get(spec.category, 0) + spec.size_bytes
            else:
                existing_count[spec.category] = existing_count.get(spec.category, 0) + 1

    # ----- Render -----
    console.print(
        f"[bold]Device:[/bold] {info.model or 'unknown'}  "
        f"[bold]Serial:[/bold] {serial}  "
        f"[bold]Firmware:[/bold] {info.software_version or 'unknown'}"
    )
    console.print(f"[bold]Archive:[/bold] {archive.dir}")

    table = Table(show_header=True, header_style="bold")
    table.add_column("category")
    table.add_column("new", justify="right")
    table.add_column("new MB", justify="right")
    table.add_column("already synced", justify="right")
    for cat in sorted(scope):
        table.add_row(
            cat.value,
            str(new_count.get(cat, 0)),
            f"{new_bytes.get(cat, 0) / 1e6:.2f}",
            str(existing_count.get(cat, 0)),
        )
    console.print(table)

    if trash:
        console.print(
            f"[yellow].Trashes:[/yellow] {len(trash)} files, "
            f"{total_bytes(trash) / 1e6:.2f} MB recoverable via "
            f"`garmin-dump trash`"
        )
    else:
        console.print("[green].Trashes:[/green] empty")

    return 0
