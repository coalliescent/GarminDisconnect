"""`.Trashes` purge.

When files are deleted via Finder/MTP they often end up in a hidden `.Trashes` folder
on the device, consuming space until manually cleared. This module finds those files
in an inventory and deletes them via `mtp-delfile`.
"""

from __future__ import annotations

from dataclasses import dataclass

from garmin_dump.mtp.delete import delete_file
from garmin_dump.mtp.inventory import Inventory, ResolvedFile
from garmin_dump.mtp.runner import MtpRunner

_TRASH_MARKER = ".trashes"


@dataclass(frozen=True)
class TrashItem:
    file_id: int
    filename: str
    size_bytes: int
    parent_path: str


def find_trash(inventory: Inventory) -> list[TrashItem]:
    """Return all files whose path includes a `.Trashes` segment."""
    items: list[TrashItem] = []
    for f in inventory.files:
        if _is_trash(f):
            items.append(
                TrashItem(
                    file_id=f.file_id,
                    filename=f.filename,
                    size_bytes=f.size_bytes,
                    parent_path=f.parent_path,
                )
            )
    return items


def _is_trash(f: ResolvedFile) -> bool:
    parts = [p.lower() for p in f.parent_path.split("/")]
    return _TRASH_MARKER in parts


def total_bytes(items: list[TrashItem]) -> int:
    return sum(i.size_bytes for i in items)


def purge(runner: MtpRunner, items: list[TrashItem]) -> tuple[int, int]:
    """Delete every TrashItem. Returns (deleted_count, freed_bytes).

    Continues past individual failures and aggregates the count of successes.
    """
    deleted = 0
    freed = 0
    for item in items:
        try:
            delete_file(runner, item.file_id)
        except Exception:
            continue
        deleted += 1
        freed += item.size_bytes
    return deleted, freed
