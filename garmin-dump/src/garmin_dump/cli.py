"""garmin-dump CLI entry point.

Wires Typer subcommands to the implementation modules in `commands/`. Keeps SQL/MTP
logic out of this file — it should read top-down as a list of subcommand declarations.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

from garmin_dump import __version__
from garmin_dump.archive.layout import Category
from garmin_dump.commands import (
    doctor as cmd_doctor,
    export as cmd_export,
    info as cmd_info,
    ingest as cmd_ingest,
    inspect as cmd_inspect,
    prune as cmd_prune,
    pull as cmd_pull,
    status as cmd_status,
    trash as cmd_trash,
)
from garmin_dump.config import Config, load_config
from garmin_dump.errors import GarminDumpError
from garmin_dump.logging_setup import setup_logging

app = typer.Typer(
    name="garmin-dump",
    help="Direct USB workout & wellness archiver for Garmin Instinct 3 Solar.",
    no_args_is_help=True,
    add_completion=False,
)

# Subcommand for `garmin-dump info {device|archive|db}`
info_app = typer.Typer(name="info", help="Local diagnostics (no device required).")
app.add_typer(info_app, name="info")


# ---------- global state passed via typer.Context.obj ----------------------------------


def _get_config(ctx: typer.Context) -> Config:
    cfg = ctx.obj.get("cfg") if ctx.obj else None
    if cfg is None:
        raise RuntimeError("config not initialized; this is a CLI bug")
    return cfg


def _argv_for_audit() -> list[str]:
    return list(sys.argv[1:])


# ---------- root callback --------------------------------------------------------------


@app.callback()
def _root(
    ctx: typer.Context,
    config: Annotated[
        Path | None,
        typer.Option("--config", help="Path to config TOML."),
    ] = None,
    archive: Annotated[
        Path | None,
        typer.Option("--archive", help="Override archive root."),
    ] = None,
    verbose: Annotated[bool, typer.Option("-v", "--verbose")] = False,
    quiet: Annotated[bool, typer.Option("-q", "--quiet")] = False,
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit machine-readable output where supported."),
    ] = False,
) -> None:
    cfg = load_config(
        config_path=config,
        archive_root=archive,
        verbose=verbose,
        quiet=quiet,
        json_output=json_output,
    )
    setup_logging(verbose=verbose, quiet=quiet, logs_dir=cfg.logs_dir)
    ctx.obj = {"cfg": cfg}


# ---------- subcommands ----------------------------------------------------------------


@app.command()
def doctor(ctx: typer.Context) -> None:
    """Preflight environment checks (toolchain, locks, archive, db)."""
    cfg = _get_config(ctx)
    code = cmd_doctor.run_doctor(cfg, console=Console())
    raise typer.Exit(code)


@app.command()
def status(
    ctx: typer.Context,
    full: Annotated[
        bool,
        typer.Option("--full", help="Include all of /GARMIN/, not just the default scope."),
    ] = False,
) -> None:
    """Show what `pull` would do right now."""
    cfg = _get_config(ctx)
    code = cmd_status.run_status(cfg, full=full, console=Console())
    raise typer.Exit(code)


@app.command()
def pull(
    ctx: typer.Context,
    full: Annotated[bool, typer.Option("--full", help="Mirror all of /GARMIN/.")] = False,
    scope: Annotated[
        list[str] | None,
        typer.Option("--scope", help="Limit to specific categories. Repeatable."),
    ] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
    limit: Annotated[
        int | None, typer.Option("--limit", help="Cap the number of files downloaded.")
    ] = None,
    no_ingest: Annotated[
        bool, typer.Option("--no-ingest", help="Skip the SQLite ingest step after download.")
    ] = False,
    verbose: Annotated[
        bool,
        typer.Option(
            "-v", "--verbose", help="Debug logging (also accepted as a global flag before `pull`)."
        ),
    ] = False,
) -> None:
    """Sync new files from the watch (default scope: activity, monitor, sleep, metrics)."""
    cfg = _get_config(ctx)
    if verbose and not cfg.verbose:
        # Per-subcommand -v wins over the global value if set.
        from garmin_dump.logging_setup import setup_logging
        setup_logging(verbose=True, quiet=False, logs_dir=cfg.logs_dir)
    opts = cmd_pull.PullOptions(
        full=full,
        scope=_parse_scope(scope),
        dry_run=dry_run,
        limit=limit,
        do_ingest=not no_ingest,
    )
    code = cmd_pull.run_pull(cfg, opts, argv=_argv_for_audit(), console=Console())
    raise typer.Exit(code)


@app.command()
def prune(
    ctx: typer.Context,
    older_than: Annotated[
        int, typer.Option("--older-than", help="Days threshold (>= 30 unless --force-young).")
    ] = 30,
    yes: Annotated[bool, typer.Option("--yes", help="Skip confirmation prompt.")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
    force_young: Annotated[
        bool,
        typer.Option(
            "--force-young",
            help="Override the 30-day floor. Use only if you know what you're doing.",
            hidden=True,
        ),
    ] = False,
) -> None:
    """Delete >30-day verified files from the watch."""
    cfg = _get_config(ctx)
    opts = cmd_prune.PruneOptions(
        older_than_days=older_than,
        yes=yes,
        dry_run=dry_run,
        force_young=force_young,
    )
    code = cmd_prune.run_prune(cfg, opts, argv=_argv_for_audit(), console=Console())
    raise typer.Exit(code)


@app.command()
def trash(
    ctx: typer.Context,
    yes: Annotated[bool, typer.Option("--yes")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
) -> None:
    """Empty the device's hidden .Trashes folder."""
    cfg = _get_config(ctx)
    code = cmd_trash.run_trash(
        cfg, yes=yes, dry_run=dry_run, argv=_argv_for_audit(), console=Console()
    )
    raise typer.Exit(code)


@app.command()
def ingest(
    ctx: typer.Context,
    reparse: Annotated[
        bool, typer.Option("--reparse", help="Drop existing parsed rows before re-inserting.")
    ] = False,
    since: Annotated[
        str | None,
        typer.Option("--since", help="Only ingest files first seen on or after this date (YYYY-MM-DD)."),
    ] = None,
    scope: Annotated[
        list[str] | None,
        typer.Option("--scope"),
    ] = None,
) -> None:
    """Re-parse archived FIT files into SQLite (no device required)."""
    cfg = _get_config(ctx)
    opts = cmd_ingest.IngestOptions(
        reparse=reparse,
        since=since,
        scope=_parse_scope(scope),
    )
    code = cmd_ingest.run_ingest(cfg, opts, argv=_argv_for_audit(), console=Console())
    raise typer.Exit(code)


@info_app.command("device")
def info_device(ctx: typer.Context) -> None:
    """Print cached device summary."""
    cfg = _get_config(ctx)
    raise typer.Exit(cmd_info.run_info_device(cfg, console=Console()))


@info_app.command("archive")
def info_archive(ctx: typer.Context) -> None:
    """Print archive bytes / file counts per device."""
    cfg = _get_config(ctx)
    raise typer.Exit(cmd_info.run_info_archive(cfg, console=Console()))


@info_app.command("db")
def info_db(ctx: typer.Context) -> None:
    """Print SQLite schema version, table row counts, and db path."""
    cfg = _get_config(ctx)
    raise typer.Exit(cmd_info.run_info_db(cfg, console=Console()))


@app.command()
def export(
    ctx: typer.Context,
    table: Annotated[str, typer.Option("--table", help="Table to export.")],
    fmt: Annotated[str, typer.Option("--format", help="csv | json | jsonl.")] = "csv",
    since: Annotated[str | None, typer.Option("--since")] = None,
    until: Annotated[str | None, typer.Option("--until")] = None,
) -> None:
    """Dump rows from a table to stdout."""
    cfg = _get_config(ctx)
    code = cmd_export.run_export(
        cfg, table=table, fmt=fmt, since=since, until=until, console=Console()
    )
    raise typer.Exit(code)


@app.command()
def inspect(
    ctx: typer.Context,
    raw: Annotated[
        bool,
        typer.Option("--raw", help="Also dump the raw mtp-files / mtp-folders text."),
    ] = False,
    show_other: Annotated[
        bool,
        typer.Option("--show-other", help="List files that bucketed as OTHER (likely categorizer misses)."),
    ] = True,
) -> None:
    """Dump the live MTP inventory for debugging. Read-only — no DB writes."""
    cfg = _get_config(ctx)
    code = cmd_inspect.run_inspect(
        cfg, raw=raw, show_other=show_other, console=Console()
    )
    raise typer.Exit(code)


@app.command()
def version(ctx: typer.Context) -> None:
    """Print garmin-dump, libmtp, and fitdecode versions plus DB schema version."""
    _ = ctx
    cfg = _get_config(ctx)
    console = Console()
    console.print(f"garmin-dump   {__version__}")
    try:
        import fitdecode
        fd_version = getattr(fitdecode, "__version__", "unknown")
    except Exception:
        fd_version = "missing"
    console.print(f"fitdecode     {fd_version}")
    try:
        from garmin_dump.mtp.runner import MtpRunner
        version_tuple = MtpRunner().libmtp_version()
        console.print("libmtp        " + ".".join(str(x) for x in version_tuple))
    except GarminDumpError as e:
        console.print(f"libmtp        [red]error:[/red] {e}")
    try:
        from garmin_dump.db.connection import Database
        from garmin_dump.db.migrations import CURRENT_VERSION, get_user_version

        if cfg.db_path.exists():
            with Database(cfg.db_path) as db:
                v = get_user_version(db.conn)
            console.print(f"schema        v{v} (latest known v{CURRENT_VERSION})")
        else:
            console.print(f"schema        not yet created (latest known v{CURRENT_VERSION})")
    except GarminDumpError as e:
        console.print(f"schema        [red]error:[/red] {e}")


# ---------- helpers --------------------------------------------------------------------


def _parse_scope(values: list[str] | None) -> frozenset[Category] | None:
    if not values:
        return None
    out: set[Category] = set()
    for raw in values:
        for token in raw.split(","):
            token = token.strip().lower()
            if not token:
                continue
            try:
                out.add(Category(token))
            except ValueError as e:
                raise typer.BadParameter(
                    f"unknown scope {token!r}; must be one of: "
                    + ", ".join(c.value for c in Category)
                ) from e
    return frozenset(out) if out else None


def main() -> None:
    """Console-script entry point."""
    try:
        app()
    except GarminDumpError as e:
        Console().print(f"[red]error:[/red] {e}")
        raise SystemExit(2) from e


if __name__ == "__main__":
    main()
