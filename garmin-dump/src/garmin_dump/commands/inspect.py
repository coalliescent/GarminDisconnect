"""`garmin-dump inspect` — debug tool that dumps the live MTP inventory.

Use this when `pull` or `status` reports zero files in a category you know should
have data, or when adding support for a new device. It performs no writes — it just
shells out to `mtp-files` / `mtp-folders` and prints the parsed tree alongside a
summary of what each file would have categorized as.

Output is split into four sections:
    1. Folder tree (parsed from `mtp-folders`)
    2. Per-folder file counts under /GARMIN/
    3. The first ~10 files in each detected folder, with their parent_path and
       categorize() bucket
    4. The full file list grouped by category
Optionally, with `--raw`, the raw stdout+stderr from both libmtp tools is dumped at
the end so the parser can be fixed against real text if it's misreading something.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from rich.console import Console
from rich.table import Table

from garmin_dump.archive.layout import Category, categorize
from garmin_dump.config import Config
from garmin_dump.errors import GarminDumpError, MtpOutputParseError
from garmin_dump.mtp.detect import detect_garmin
from garmin_dump.mtp.inventory import (
    Inventory,
    build_inventory,
    fetch_inventory,
)
from garmin_dump.mtp.runner import LONG_TIMEOUT_S, MtpRunner


def run_inspect(
    cfg: Config,
    *,
    raw: bool,
    show_other: bool,
    console: Console | None = None,
) -> int:
    console = console or Console()
    runner = MtpRunner()
    try:
        runner.assert_libmtp_supported()
        device = detect_garmin(runner)
    except GarminDumpError as e:
        console.print(f"[red]error:[/red] {e}")
        return 2
    console.print(
        f"[bold]Device:[/bold] {device.product or device.vendor} "
        f"(VID={device.vendor_id} PID={device.product_id})"
    )

    # Capture the raw text up front so we can show it on parse failure as well as
    # on the user's request.
    files_result = runner.run("mtp-files", timeout=LONG_TIMEOUT_S)
    folders_result = runner.run("mtp-folders", timeout=LONG_TIMEOUT_S)
    files_text = files_result.combined
    folders_text = folders_result.combined

    try:
        inventory = build_inventory(files_text, folders_text)
    except MtpOutputParseError as e:
        console.print(f"[red]parser error:[/red] {e}")
        console.print("[yellow]Dumping raw output below so the parser can be fixed:[/yellow]")
        _dump_raw(console, files_text, folders_text)
        return 2

    _print_folder_tree(console, inventory)
    _print_per_folder_summary(console, inventory)
    _print_category_summary(console, inventory, show_other=show_other)

    if raw:
        _dump_raw(console, files_text, folders_text)

    return 0


# ---- renderers -------------------------------------------------------------------------


def _print_folder_tree(console: Console, inv: Inventory) -> None:
    console.rule("[bold]folder tree (parsed from mtp-folders)[/bold]")
    if not inv.folders:
        console.print("[red](empty — mtp-folders output produced no folder entries)[/red]")
        return
    by_parent: dict[int, list[int]] = defaultdict(list)
    for f in inv.folders.values():
        by_parent[f.parent_id].append(f.folder_id)
    # Find roots (folders whose parent isn't itself a known folder).
    known_ids = set(inv.folders)
    root_ids = sorted(
        fid for fid, fent in inv.folders.items()
        if fent.parent_id not in known_ids
    )
    for root in root_ids:
        _walk_folder(console, inv, root, by_parent, prefix="")
    console.print(f"[dim]{len(inv.folders)} folders parsed[/dim]")


def _walk_folder(
    console: Console,
    inv: Inventory,
    fid: int,
    by_parent: dict[int, list[int]],
    *,
    prefix: str,
) -> None:
    f = inv.folders.get(fid)
    if f is None:
        return
    label = f"{prefix}{f.name}  [dim](id={f.folder_id} parent={f.parent_id})[/dim]"
    console.print(label)
    for child in by_parent.get(fid, []):
        _walk_folder(console, inv, child, by_parent, prefix=prefix + "  ")


def _print_per_folder_summary(console: Console, inv: Inventory) -> None:
    console.rule("[bold]files grouped by parent_path[/bold]")
    by_parent: dict[str, list] = defaultdict(list)
    for f in inv.files:
        by_parent[f.parent_path].append(f)
    if not by_parent:
        console.print("[red](no files parsed from mtp-files output)[/red]")
        return
    table = Table(show_header=True, header_style="bold")
    table.add_column("parent_path")
    table.add_column("count", justify="right")
    table.add_column("MB", justify="right")
    table.add_column("categorize() →")
    table.add_column("sample file")
    for parent in sorted(by_parent):
        files = by_parent[parent]
        cat = categorize(parent)
        size = sum(f.size_bytes for f in files) / 1e6
        sample = files[0].filename if files else ""
        cat_label = cat.value
        if cat is Category.OTHER:
            cat_label = f"[yellow]{cat_label}[/yellow]"
        else:
            cat_label = f"[green]{cat_label}[/green]"
        table.add_row(parent, str(len(files)), f"{size:.2f}", cat_label, sample)
    console.print(table)


def _print_category_summary(
    console: Console, inv: Inventory, *, show_other: bool
) -> None:
    console.rule("[bold]files grouped by category[/bold]")
    by_cat: dict[Category, list] = defaultdict(list)
    for f in inv.files:
        by_cat[f.category].append(f)
    table = Table(show_header=True, header_style="bold")
    table.add_column("category")
    table.add_column("files", justify="right")
    table.add_column("MB", justify="right")
    for cat in sorted(by_cat):
        files = by_cat[cat]
        table.add_row(
            cat.value,
            str(len(files)),
            f"{sum(f.size_bytes for f in files) / 1e6:.2f}",
        )
    console.print(table)
    if show_other and (others := by_cat.get(Category.OTHER)):
        console.print("\n[bold]first 30 OTHER-bucketed files (likely a categorize miss):[/bold]")
        for f in others[:30]:
            console.print(f"  {f.parent_path}/{f.filename}  ({f.size_bytes} B)")


def _dump_raw(console: Console, files_text: str, folders_text: str) -> None:
    console.rule("[bold]raw mtp-files output[/bold]")
    console.print(files_text)
    console.rule("[bold]raw mtp-folders output[/bold]")
    console.print(folders_text)


# silence linter
_ = Path
