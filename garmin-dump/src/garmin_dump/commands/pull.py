"""`garmin-dump pull` — the main sync orchestrator.

This is the heart of the project. The algorithm is documented in detail in
`plan.md`'s "Sync algorithm" section. Quick recap:

    1. Preflight: refuse if Garmin Express et al. are running.
    2. Detect device, locate /GARMIN/GarminDevice.xml, parse identity.
    3. Inventory the device once via mtp-files + mtp-folders.
    4. Diff against sync_log; build the to-fetch set.
    5. Sequential download loop with size+SHA verification, atomic rename, sync_log
       updates after each file. One stale-ID retry per session.
    6. Detect remote deletions (rows verified previously but not seen this run).
    7. Optional ingest pass for newly-verified files.
    8. Finalize the runs row, print summary.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from rich.console import Console
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
)

from garmin_dump.archive.layout import (
    GARMIN_DEVICE_XML,
    Category,
    DeviceArchive,
    relative_to_archive,
)
from garmin_dump.archive.sync_log import (
    RemoteFileSpec,
    begin_pending,
    detect_remote_deletions,
    lookup,
    needs_download,
)
from garmin_dump.config import Config, ensure_dirs
from garmin_dump.db import repo
from garmin_dump.db.connection import Database
from garmin_dump.device.garmin_xml import (
    DeviceInfo,
    device_info_to_json,
    parse_garmin_device_xml,
)
from garmin_dump.errors import (
    ArchiveError,
    GarminDumpError,
    GarminXmlError,
    MtpError,
    MtpFileNotFoundError,
    MtpOutputParseError,
)
from garmin_dump.ingest.dispatcher import ingest_file
from garmin_dump.logging_setup import get_logger
from garmin_dump.mtp.detect import detect_garmin
from garmin_dump.mtp.download import download_file, gc_tmp
from garmin_dump.mtp.inventory import Inventory, ResolvedFile, fetch_inventory
from garmin_dump.mtp.runner import MtpRunner

log = get_logger()

DEFAULT_CATEGORIES: frozenset[Category] = frozenset(
    {Category.ACTIVITY, Category.MONITOR, Category.SLEEP, Category.METRICS}
)
ALL_CATEGORIES: frozenset[Category] = frozenset(Category)


@dataclass
class PullOptions:
    full: bool = False
    scope: frozenset[Category] | None = None
    dry_run: bool = False
    limit: int | None = None
    do_ingest: bool = True


@dataclass
class PullSummary:
    device_serial: str | None = None
    files_seen: int = 0
    files_to_fetch: int = 0
    files_downloaded: int = 0
    bytes_downloaded: int = 0
    errors: list[str] = field(default_factory=list)
    deleted_remote: int = 0
    ingested_activities: int = 0
    ingested_sleeps: int = 0
    ingested_samples: int = 0
    parser_errors: int = 0


def run_pull(
    cfg: Config,
    opts: PullOptions,
    *,
    argv: list[str],
    console: Console | None = None,
) -> int:
    """Execute a pull. Returns the exit code (0 = clean, 2 = error)."""
    console = console or Console()
    ensure_dirs(cfg)
    runner = MtpRunner()
    summary = PullSummary()

    # ----- Preflight ----------------------------------------------------------------
    # Note: we deliberately do NOT assert there are no MTP lock holders running.
    # On modern macOS, icdd / cameracaptured / photolibraryd are always running and
    # libmtp coexists fine with them for Garmin watches. mtp-detect's success or
    # failure is the only authoritative gate. If a real conflict ever surfaces, the
    # `doctor` INFO row plus the actual mtp-detect error will explain it.
    try:
        runner.assert_libmtp_supported()
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2

    # GC orphaned temp files from prior interrupted runs.
    n_gc = gc_tmp(cfg.tmp_dir)
    if n_gc:
        log.debug("garbage-collected %d stale .partial files", n_gc)

    # ----- Database ------------------------------------------------------------------
    with Database(cfg.db_path) as db:
        run = repo.start_run(db.conn, subcommand="pull", argv=argv)

        try:
            # ----- Detect + identify --------------------------------------------------
            try:
                detect_garmin(runner)
            except GarminDumpError as e:
                console.print(f"[red]error:[/red] {e}")
                repo.finish_run(
                    db.conn, run.run_id, exit_code=2, errors_count=1
                )
                return 2

            try:
                inventory, files_raw, folders_raw = fetch_inventory(runner)
            except MtpOutputParseError as e:
                _dump_raw_output(cfg.logs_dir, e)
                console.print(f"[red]error:[/red] {e}")
                repo.finish_run(db.conn, run.run_id, exit_code=2, errors_count=1)
                return 2

            try:
                info = _read_device_xml(runner, inventory, cfg.tmp_dir)
            except (GarminXmlError, MtpError) as e:
                console.print(f"[red]error:[/red] {e}")
                repo.finish_run(db.conn, run.run_id, exit_code=2, errors_count=1)
                return 2

            serial = info.archive_serial
            summary.device_serial = serial

            # Persist device + cached XML/json
            device_id = repo.upsert_device(
                db.conn,
                repo.DeviceUpsert(
                    serial=serial,
                    unit_id=info.unit_id,
                    part_number=info.part_number,
                    model=info.model,
                    software_version=info.software_version,
                ),
            )

            archive = DeviceArchive(cfg.archive_root, serial)
            archive.ensure_dirs()
            archive.garmin_xml_path.write_bytes(_xml_bytes_from_inventory(runner, inventory, cfg.tmp_dir))
            archive.device_json_path.write_text(device_info_to_json(info), encoding="utf-8")

            # ----- Diff ---------------------------------------------------------------
            scope = _resolve_scope(opts)
            console.print(
                f"[bold]Device:[/bold] {info.model or 'unknown'} (serial {serial})  "
                f"[bold]Scope:[/bold] {sorted(scope)}"
            )

            specs = _select_specs(inventory, scope)
            summary.files_seen = len(specs)
            seen_keys = {(s.parent_path, s.filename, s.size_bytes) for s in specs}

            to_fetch: list[RemoteFileSpec] = []
            for spec in specs:
                row = lookup(db.conn, device_id, spec)
                if needs_download(row):
                    to_fetch.append(spec)
            if opts.limit is not None:
                to_fetch = to_fetch[: opts.limit]
            summary.files_to_fetch = len(to_fetch)

            if opts.dry_run:
                _print_dry_run(console, specs, to_fetch)
                summary.deleted_remote = detect_remote_deletions(
                    db.conn, device_id, seen_keys
                )
                _finalize(db, run.run_id, summary, device_id, exit_code=0)
                return 0

            # ----- Download loop ------------------------------------------------------
            stale_retry_used = False
            inventory_by_id: dict[int, ResolvedFile] = {f.file_id: f for f in inventory.files}

            with _make_progress(console) as progress:
                task = progress.add_task("downloading", total=len(to_fetch))
                for spec in to_fetch:
                    sync_id = begin_pending(db.conn, device_id, spec)
                    target = archive.file_path(
                        spec.category,
                        spec.filename,
                        full_relative=spec.parent_path + "/" + spec.filename
                        if spec.category is Category.OTHER
                        else None,
                    )
                    try:
                        result = download_file(
                            runner,
                            file_id=spec.file_id,
                            expected_size=spec.size_bytes,
                            tmp_dir=cfg.tmp_dir,
                            final_path=target,
                        )
                    except MtpFileNotFoundError as e:
                        # Stale ID — refresh inventory once and retry this file.
                        if stale_retry_used:
                            _record_failure(db.conn, sync_id, summary, str(e))
                            progress.advance(task)
                            continue
                        stale_retry_used = True
                        log.warning("stale MTP id detected; refreshing inventory once: %s", e)
                        try:
                            inventory, files_raw, folders_raw = fetch_inventory(runner)
                            inventory_by_id = {f.file_id: f for f in inventory.files}
                        except MtpOutputParseError as parse_err:
                            _dump_raw_output(cfg.logs_dir, parse_err)
                            _record_failure(db.conn, sync_id, summary, str(parse_err))
                            progress.advance(task)
                            continue
                        # Re-look-up by stable key
                        match = _match_by_key(inventory, spec)
                        if match is None:
                            _record_failure(
                                db.conn, sync_id, summary,
                                "file disappeared from device after refresh",
                            )
                            progress.advance(task)
                            continue
                        spec = RemoteFileSpec(
                            parent_path=spec.parent_path,
                            filename=spec.filename,
                            size_bytes=spec.size_bytes,
                            file_id=match.file_id,
                            category=spec.category,
                        )
                        try:
                            result = download_file(
                                runner,
                                file_id=spec.file_id,
                                expected_size=spec.size_bytes,
                                tmp_dir=cfg.tmp_dir,
                                final_path=target,
                            )
                        except (MtpError, ArchiveError) as retry_err:
                            _record_failure(db.conn, sync_id, summary, str(retry_err))
                            progress.advance(task)
                            continue
                    except (MtpError, ArchiveError) as e:
                        _record_failure(db.conn, sync_id, summary, str(e))
                        progress.advance(task)
                        continue

                    repo.mark_sync_verified(
                        db.conn,
                        sync_id,
                        sha256=result.sha256,
                        local_path=relative_to_archive(cfg.archive_root, result.final_path),
                    )
                    summary.files_downloaded += 1
                    summary.bytes_downloaded += result.size_bytes

                    # Periodic checkpoint to keep WAL bounded.
                    if summary.files_downloaded % 25 == 0:
                        _checkpoint(db)

                    if opts.do_ingest:
                        ir = ingest_file(
                            db.conn,
                            sync_id=sync_id,
                            device_id=device_id,
                            file_sha256=result.sha256,
                            path=result.final_path,
                            category_hint=spec.category,
                        )
                        if ir.activity_id is not None:
                            summary.ingested_activities += 1
                        if ir.sleep_id is not None:
                            summary.ingested_sleeps += 1
                        summary.ingested_samples += ir.sample_count
                        if ir.error is not None:
                            summary.parser_errors += 1

                    # Periodic flush of run counters so a ^C still leaves a useful row.
                    if summary.files_downloaded % 10 == 0:
                        repo.finish_run(
                            db.conn, run.run_id,
                            files_seen=summary.files_seen,
                            files_downloaded=summary.files_downloaded,
                            bytes_downloaded=summary.bytes_downloaded,
                            errors_count=len(summary.errors) + summary.parser_errors,
                            device_id=device_id,
                        )

                    progress.advance(task)

            # ----- Detect remote deletions --------------------------------------------
            summary.deleted_remote = detect_remote_deletions(db.conn, device_id, seen_keys)

            _checkpoint(db)
            exit_code = 0 if not summary.errors else 1
            _finalize(db, run.run_id, summary, device_id, exit_code=exit_code)
            _print_summary(console, summary)
            return exit_code

        except Exception as e:  # pragma: no cover - top-level safety net
            log.exception("pull crashed")
            console.print(f"[red]fatal:[/red] {e}")
            repo.finish_run(db.conn, run.run_id, exit_code=2, errors_count=1)
            return 2


# ---- helpers ---------------------------------------------------------------------------


def _resolve_scope(opts: PullOptions) -> frozenset[Category]:
    if opts.scope is not None:
        return opts.scope
    if opts.full:
        return ALL_CATEGORIES
    return DEFAULT_CATEGORIES


def _select_specs(inventory: Inventory, scope: frozenset[Category]) -> list[RemoteFileSpec]:
    """Filter inventory to specs matching the active scope.

    Iterates `inventory.files` directly. Earlier versions filtered through an
    `under_garmin()` helper that required `parent_path` to start with `/garmin`,
    which dropped 100% of real Instinct 3 content because the watch puts user data
    folders at the storage root, not nested under a GARMIN parent.
    """
    specs: list[RemoteFileSpec] = []
    for f in inventory.files:
        if f.category not in scope:
            continue
        specs.append(
            RemoteFileSpec(
                parent_path=f.parent_path,
                filename=f.filename,
                size_bytes=f.size_bytes,
                file_id=f.file_id,
                category=f.category,
            )
        )
    # Sort for deterministic ordering / friendly progress.
    specs.sort(key=lambda s: (s.parent_path, s.filename))
    return specs


def _match_by_key(inventory: Inventory, spec: RemoteFileSpec) -> ResolvedFile | None:
    for f in inventory.files:
        if (
            f.parent_path == spec.parent_path
            and f.filename == spec.filename
            and f.size_bytes == spec.size_bytes
        ):
            return f
    return None


def _read_device_xml(
    runner: MtpRunner, inventory: Inventory, tmp_dir: Path
) -> DeviceInfo:
    """Find GarminDevice.xml in the inventory, download it, parse it."""
    xml_bytes = _xml_bytes_from_inventory(runner, inventory, tmp_dir)
    return parse_garmin_device_xml(xml_bytes)


def _xml_bytes_from_inventory(
    runner: MtpRunner, inventory: Inventory, tmp_dir: Path
) -> bytes:
    for f in inventory.files:
        if f.filename == GARMIN_DEVICE_XML:
            tmp_dir.mkdir(parents=True, exist_ok=True)
            target = tmp_dir / GARMIN_DEVICE_XML
            from garmin_dump.mtp.download import download_file as _dl
            try:
                result = _dl(
                    runner,
                    file_id=f.file_id,
                    expected_size=f.size_bytes,
                    tmp_dir=tmp_dir,
                    final_path=target,
                )
            except (MtpError, ArchiveError) as e:
                raise GarminXmlError(f"could not download GarminDevice.xml: {e}") from e
            return result.final_path.read_bytes()
    raise GarminXmlError(
        "GarminDevice.xml not found in MTP inventory. The watch may not be a "
        "supported Garmin device, or the file is in an unexpected location."
    )


def _record_failure(
    conn, sync_id: int, summary: PullSummary, message: str
) -> None:
    repo.mark_sync_failed(conn, sync_id, error_message=message)
    summary.errors.append(message)
    log.warning("download failed: %s", message)


def _checkpoint(db: Database) -> None:
    try:
        db.conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
    except Exception:  # pragma: no cover
        pass


def _finalize(
    db: Database,
    run_id: int,
    summary: PullSummary,
    device_id: int | None,
    *,
    exit_code: int,
) -> None:
    repo.finish_run(
        db.conn,
        run_id,
        files_seen=summary.files_seen,
        files_downloaded=summary.files_downloaded,
        bytes_downloaded=summary.bytes_downloaded,
        errors_count=len(summary.errors) + summary.parser_errors,
        exit_code=exit_code,
        device_id=device_id,
    )


def _make_progress(console: Console) -> Progress:
    return Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeElapsedColumn(),
        console=console,
        transient=False,
    )


def _print_dry_run(
    console: Console, specs: Iterable[RemoteFileSpec], to_fetch: list[RemoteFileSpec]
) -> None:
    by_cat: dict[Category, int] = {}
    bytes_by_cat: dict[Category, int] = {}
    for s in to_fetch:
        by_cat[s.category] = by_cat.get(s.category, 0) + 1
        bytes_by_cat[s.category] = bytes_by_cat.get(s.category, 0) + s.size_bytes
    total_bytes = sum(bytes_by_cat.values())
    console.print("[bold]dry run:[/bold] would download:")
    for cat in sorted(by_cat):
        console.print(f"  {cat:<10}  {by_cat[cat]:>5} files  {bytes_by_cat[cat] / 1e6:>8.2f} MB")
    console.print(
        f"  [bold]total[/bold]      {len(to_fetch):>5} files  {total_bytes / 1e6:>8.2f} MB"
    )


def _print_summary(console: Console, s: PullSummary) -> None:
    console.print()
    console.print(f"[bold]Pull complete[/bold]  device={s.device_serial}")
    console.print(
        f"  files seen:       {s.files_seen}\n"
        f"  files downloaded: {s.files_downloaded}\n"
        f"  bytes downloaded: {s.bytes_downloaded / 1e6:.2f} MB\n"
        f"  remote deletions: {s.deleted_remote}\n"
        f"  ingested:         "
        f"{s.ingested_activities} activities, "
        f"{s.ingested_sleeps} sleeps, "
        f"{s.ingested_samples} samples\n"
        f"  parser errors:    {s.parser_errors}\n"
        f"  download errors:  {len(s.errors)}"
    )
    if s.errors:
        console.print("[yellow]first 5 errors:[/yellow]")
        for e in s.errors[:5]:
            console.print(f"  - {e}")


def _dump_raw_output(logs_dir: Path, exc: MtpOutputParseError) -> Path:
    """Write the raw stdout from a parser failure for forensics."""
    from datetime import datetime as _dt
    logs_dir.mkdir(parents=True, exist_ok=True)
    ts = _dt.utcnow().strftime("%Y%m%dT%H%M%SZ")
    target = logs_dir / f"{exc.tool}-{ts}.txt"
    target.write_text(exc.raw_output, encoding="utf-8")
    log.error("dumped raw %s output to %s", exc.tool, target)
    return target


# Silence linters complaining about unused imports
_ = (sys,)
