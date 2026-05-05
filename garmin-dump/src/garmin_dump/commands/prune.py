"""`garmin-dump prune` — delete >30-day verified files from the watch.

Safety rules (all enforced; --force-young is the only escape):
    1. The file must be in `verified` status in sync_log.
    2. The local archive copy must exist.
    3. The local copy's freshly-recomputed SHA-256 must match sync_log.sha256.
    4. The first_seen_utc must be older than `cutoff_iso(retention_days)`.
    5. retention_days defaults to cfg.retention_days (30) and cannot go below 30
       unless --force-young is set on the command line.

Manual confirmation prompt by default. `--yes` skips it for unattended runs.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.prompt import Confirm

from garmin_dump.archive.hashing import sha256_file
from garmin_dump.archive.sync_log import list_prune_candidates
from garmin_dump.config import Config, MIN_RETENTION_DAYS
from garmin_dump.db import repo
from garmin_dump.db.connection import Database
from garmin_dump.errors import (
    GarminDumpError,
    HashMismatchError,
    MtpError,
)
from garmin_dump.mtp.delete import delete_file
from garmin_dump.mtp.detect import detect_garmin
from garmin_dump.mtp.inventory import fetch_inventory
from garmin_dump.mtp.runner import MtpRunner
from garmin_dump.commands.pull import _read_device_xml


@dataclass
class PruneOptions:
    older_than_days: int = 30
    yes: bool = False
    dry_run: bool = False
    force_young: bool = False


def run_prune(
    cfg: Config,
    opts: PruneOptions,
    *,
    argv: list[str],
    console: Console | None = None,
) -> int:
    console = console or Console()

    days = opts.older_than_days
    if days < MIN_RETENTION_DAYS and not opts.force_young:
        console.print(
            f"[red]error:[/red] --older-than {days} is below the {MIN_RETENTION_DAYS}-day "
            f"floor. The watch needs multi-week data for VO2 max, HRV, and body battery. "
            f"Use --force-young if you really mean it."
        )
        return 2

    runner = MtpRunner()
    try:
        runner.assert_libmtp_supported()
        detect_garmin(runner)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2

    try:
        inventory, _, _ = fetch_inventory(runner)
        info = _read_device_xml(runner, inventory, cfg.tmp_dir)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2
    serial = info.archive_serial

    # Map (parent_path, filename, size) → file_id from the live inventory; we need the
    # file_id to call mtp-delfile. We never trust an old file_id from the database.
    live_id_by_key: dict[tuple[str, str, int], int] = {}
    for f in inventory.files:
        live_id_by_key[(f.parent_path, f.filename, f.size_bytes)] = f.file_id

    with Database(cfg.db_path) as db:
        run = repo.start_run(db.conn, subcommand="prune", argv=argv)

        device_row = repo.get_device_by_serial(db.conn, serial)
        if device_row is None:
            console.print(
                "[yellow]warning:[/yellow] this device has no prior sync. Run "
                "`garmin-dump pull` first; nothing to prune."
            )
            repo.finish_run(db.conn, run.run_id, exit_code=0)
            return 0
        device_id = int(device_row["device_id"])

        candidates = list_prune_candidates(
            db.conn, device_id=device_id, retention_days=days
        )
        eligible: list[tuple[int, int, int, str]] = []  # (sync_id, file_id, size, key)
        skipped: list[str] = []

        for row in candidates:
            sync_id = int(row["sync_id"])
            local_rel = row["local_path"]
            sha = row["sha256"]
            if not local_rel or not sha:
                skipped.append(f"sync_id={sync_id}: missing local_path or sha256")
                continue
            local = cfg.archive_root / local_rel
            if not local.is_file():
                skipped.append(f"sync_id={sync_id}: local file missing at {local}")
                continue
            try:
                actual_sha = sha256_file(local)
            except OSError as e:
                skipped.append(f"sync_id={sync_id}: read failed: {e}")
                continue
            if actual_sha != sha:
                skipped.append(
                    f"sync_id={sync_id}: SHA mismatch (expected {sha[:8]}, got {actual_sha[:8]})"
                )
                continue

            key = (row["remote_parent"], row["filename"], int(row["size_bytes"]))
            file_id = live_id_by_key.get(key)
            if file_id is None:
                # File no longer present on the device — mark as deleted_remote and move on.
                repo.mark_sync_deleted_remote(db.conn, sync_id)
                skipped.append(
                    f"sync_id={sync_id}: not on device (already gone), marked deleted_remote"
                )
                continue
            eligible.append((sync_id, file_id, int(row["size_bytes"]), str(local)))

        if not eligible:
            console.print(
                f"[green]nothing to prune.[/green] "
                f"{len(candidates)} candidates examined, {len(skipped)} skipped."
            )
            for s in skipped[:10]:
                console.print(f"  - {s}")
            repo.finish_run(db.conn, run.run_id, exit_code=0)
            return 0

        total_bytes = sum(b for _, _, b, _ in eligible)
        console.print(
            f"[bold]Prune candidates:[/bold] {len(eligible)} files, "
            f"{total_bytes / 1e6:.2f} MB on the watch (older than {days} days, "
            f"verified+hash-matched)"
        )

        if opts.dry_run:
            for sid, fid, sz, p in eligible[:20]:
                console.print(f"  would delete file_id={fid} sync_id={sid} ({sz} B) <- {p}")
            if len(eligible) > 20:
                console.print(f"  … and {len(eligible) - 20} more")
            repo.finish_run(db.conn, run.run_id, exit_code=0)
            return 0

        if not opts.yes:
            if not Confirm.ask(
                f"Delete {len(eligible)} files freeing {total_bytes / 1e6:.2f} MB on the watch?",
                default=False,
            ):
                console.print("[yellow]aborted.[/yellow]")
                repo.finish_run(db.conn, run.run_id, exit_code=0)
                return 0

        deleted = 0
        freed = 0
        errors = 0
        for sync_id, file_id, size, _ in eligible:
            try:
                delete_file(runner, file_id)
                repo.mark_sync_deleted_remote(db.conn, sync_id)
                deleted += 1
                freed += size
            except MtpError as e:
                errors += 1
                console.print(f"[red]delete failed[/red] sync_id={sync_id}: {e}")

        console.print(
            f"[green]done.[/green] deleted {deleted}/{len(eligible)} files "
            f"({freed / 1e6:.2f} MB), {errors} errors."
        )
        repo.finish_run(
            db.conn,
            run.run_id,
            files_deleted=deleted,
            errors_count=errors,
            exit_code=0 if errors == 0 else 1,
            device_id=device_id,
        )
        return 0 if errors == 0 else 1


# silence linters
_ = (HashMismatchError, Path)
