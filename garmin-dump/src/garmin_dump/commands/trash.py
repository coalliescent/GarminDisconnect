"""`garmin-dump trash` — empty the device's hidden `.Trashes` folder."""

from __future__ import annotations

from rich.console import Console
from rich.prompt import Confirm

from garmin_dump.commands.pull import _read_device_xml
from garmin_dump.config import Config
from garmin_dump.db import repo
from garmin_dump.db.connection import Database
from garmin_dump.errors import GarminDumpError
from garmin_dump.mtp.detect import detect_garmin
from garmin_dump.mtp.inventory import fetch_inventory
from garmin_dump.mtp.runner import MtpRunner
from garmin_dump.mtp.trash import find_trash, purge, total_bytes


def run_trash(
    cfg: Config,
    *,
    yes: bool,
    dry_run: bool,
    argv: list[str],
    console: Console | None = None,
) -> int:
    console = console or Console()
    runner = MtpRunner()
    try:
        runner.assert_libmtp_supported()
        detect_garmin(runner)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2

    inventory, _, _ = fetch_inventory(runner)
    info = _read_device_xml(runner, inventory, cfg.tmp_dir)
    items = find_trash(inventory)

    if not items:
        console.print("[green].Trashes is empty.[/green]")
        return 0

    bytes_total = total_bytes(items)
    console.print(
        f"[bold]Found {len(items)} files in .Trashes[/bold] "
        f"({bytes_total / 1e6:.2f} MB)"
    )

    if dry_run:
        for item in items[:20]:
            console.print(f"  {item.parent_path}/{item.filename}  ({item.size_bytes} B)")
        if len(items) > 20:
            console.print(f"  … and {len(items) - 20} more")
        return 0

    if not yes and not Confirm.ask("Delete all .Trashes contents?", default=False):
        console.print("[yellow]aborted.[/yellow]")
        return 0

    with Database(cfg.db_path) as db:
        run = repo.start_run(db.conn, subcommand="trash", argv=argv)
        deleted, freed = purge(runner, items)
        console.print(
            f"[green]done.[/green] removed {deleted}/{len(items)} files "
            f"({freed / 1e6:.2f} MB freed)"
        )
        repo.finish_run(
            db.conn,
            run.run_id,
            files_deleted=deleted,
            errors_count=len(items) - deleted,
            exit_code=0 if deleted == len(items) else 1,
        )
    # Pre-cache the device for the audit row
    _ = info
    return 0
