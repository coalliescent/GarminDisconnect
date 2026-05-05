"""Parse `mtp-files` + `mtp-folders` output into an in-memory FS tree.

This is the highest-risk file in the project: libmtp's CLI tools are technically
"example" code, not a stable API, and their output format has shifted a couple of times
historically. We:

    - Parse defensively (tolerate unknown/extra fields, blank lines, banners).
    - Dump raw output to a log on parse failure (caller's responsibility) and raise
      `MtpOutputParseError` rather than synthesizing fake inventory.
    - Reconstruct paths from `Parent ID` chains. We never trust the file ID for any
      purpose other than the immediately-following `mtp-getfile` call within the same
      session.

Format reference (libmtp 1.1.21+):

    mtp-files:
        Listing File Information on Device with name: <name>
        File ID: <int>
           Filename: <name>
           File size <bytes> (0x<hex> bytes)
           Parent ID: <int>
           Storage ID: 0x<hex>
           Filetype: <type>          # "Folder" for folders

    mtp-folders:
        Folder list for storage <name>
        Storage: <storage_id>
        <indent>%u %s\\n             # depth = indent / 2; ID then name

We do not require any of the surrounding banner text. The parsers key off the
recognizable per-record markers and silently skip everything else.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from garmin_dump.archive.layout import Category, categorize
from garmin_dump.errors import MtpOutputParseError
from garmin_dump.mtp.runner import LONG_TIMEOUT_S, MtpRunner

# Sentinel parent IDs that mean "no parent" / "storage root". libmtp uses 0 for the
# storage root in most folder listings; some firmwares emit 0xFFFFFFFF instead.
_ROOT_PARENT_IDS = frozenset({0, 0xFFFFFFFF})


# ---- data classes ----------------------------------------------------------------------


@dataclass(frozen=True)
class FolderEntry:
    folder_id: int
    name: str
    parent_id: int
    depth: int


@dataclass(frozen=True)
class FileEntry:
    file_id: int
    filename: str
    size_bytes: int
    parent_id: int
    storage_id: int | None
    filetype: str


@dataclass(frozen=True)
class ResolvedFile:
    """A FileEntry with its absolute path resolved against the folder tree.

    Garmin's MTP exposes user-data folders directly under the storage root. So a
    typical resolved path on the Instinct 3 looks like `/Activity` or `/Monitor`,
    NOT `/GARMIN/Activity`. We deliberately do NOT require a `/GARMIN/` prefix:
    older Forerunners and Edges nest content under a GARMIN folder, but the
    Instinct 3 (and probably other modern wrist devices) put it at the storage
    root. `categorize()` walks every path component case-insensitively, so both
    layouts work without special-casing.
    """

    file_id: int
    filename: str
    size_bytes: int
    parent_path: str         # e.g. "/Activity" or "/GARMIN/Activity" depending on device
    full_path: str           # parent_path + "/" + filename
    category: Category


@dataclass
class Inventory:
    folders: dict[int, FolderEntry] = field(default_factory=dict)
    files: list[ResolvedFile] = field(default_factory=list)


# ---- parsers ---------------------------------------------------------------------------


_FILE_HEADER_RE = re.compile(r"^File ID:\s*(\d+)\s*$")
_FILE_FIELD_RE = re.compile(r"^\s+(\w[\w ]*?):\s*(.+?)\s*$")
_FILE_SIZE_RE = re.compile(r"^\s+File size\s+(\d+)", re.IGNORECASE)


def parse_mtp_files(stdout: str) -> list[FileEntry]:
    """Parse `mtp-files` stdout into FileEntry records.

    Raises MtpOutputParseError on a malformed File ID block. Tolerant of unknown
    fields and surrounding banner text.
    """
    entries: list[FileEntry] = []
    current: dict[str, str] | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        try:
            entries.append(_finalize_file(current))
        except (KeyError, ValueError) as e:
            raise MtpOutputParseError(
                "mtp-files",
                f"could not finalize file record: {e}; partial = {current!r}",
                stdout,
            ) from e
        current = None

    for raw_line in stdout.splitlines():
        m_header = _FILE_HEADER_RE.match(raw_line)
        if m_header:
            flush()
            current = {"_file_id": m_header.group(1)}
            continue
        if current is None:
            continue
        m_size = _FILE_SIZE_RE.match(raw_line)
        if m_size:
            current["_size"] = m_size.group(1)
            continue
        m_field = _FILE_FIELD_RE.match(raw_line)
        if m_field:
            key = m_field.group(1).strip().lower()
            current[key] = m_field.group(2).strip()
    flush()
    return entries


def _finalize_file(d: dict[str, str]) -> FileEntry:
    file_id = int(d["_file_id"])
    filename = d.get("filename", "")
    size_bytes = int(d.get("_size", "0"))
    parent_id = int(d.get("parent id", "0"))
    storage_raw = d.get("storage id")
    storage_id: int | None = None
    if storage_raw:
        storage_id = _parse_int(storage_raw)
    filetype = d.get("filetype", "")
    return FileEntry(
        file_id=file_id,
        filename=filename,
        size_bytes=size_bytes,
        parent_id=parent_id,
        storage_id=storage_id,
        filetype=filetype,
    )


def _parse_int(s: str) -> int:
    """Parse `1234`, `0x1f`, or `0X1F`."""
    s = s.strip()
    if s.lower().startswith("0x"):
        return int(s, 16)
    return int(s)


_FOLDER_LINE_RE = re.compile(r"^(?P<indent>\s*)(?P<id>\d+|0x[0-9a-fA-F]+)\s+(?P<name>.+?)\s*$")


def parse_mtp_folders(stdout: str) -> dict[int, FolderEntry]:
    """Parse `mtp-folders` indented tree into a dict keyed by folder_id.

    libmtp's `mtp-folders` recursively prints `<2*depth-spaces><id> <name>`. We
    reconstruct parent_id from the most recent line at depth-1.
    """
    folders: dict[int, FolderEntry] = {}
    # Stack of (depth, folder_id) to compute parent at each line.
    stack: list[tuple[int, int]] = []
    for raw_line in stdout.splitlines():
        if not raw_line.strip():
            continue
        # Skip banner / header lines that don't begin with whitespace+digit.
        m = _FOLDER_LINE_RE.match(raw_line)
        if not m:
            continue
        indent = m.group("indent")
        # libmtp uses 2 spaces per depth level; tabs map to 1 level just in case.
        depth = (len(indent.replace("\t", "  "))) // 2
        try:
            folder_id = _parse_int(m.group("id"))
        except ValueError:
            continue
        name = m.group("name").strip()
        # Pop the stack until its top is at depth-1 (or empty if depth==0).
        while stack and stack[-1][0] >= depth:
            stack.pop()
        parent_id = stack[-1][1] if stack else 0
        folders[folder_id] = FolderEntry(
            folder_id=folder_id,
            name=name,
            parent_id=parent_id,
            depth=depth,
        )
        stack.append((depth, folder_id))
    return folders


# ---- path resolution -------------------------------------------------------------------


def _resolve_path(folders: dict[int, FolderEntry], parent_id: int) -> str:
    """Walk the parent chain up to a root and return an absolute path string.

    A path of "/" means "lives directly at a storage root" (no enclosing folder).
    """
    parts: list[str] = []
    visited: set[int] = set()
    cur = parent_id
    while cur not in _ROOT_PARENT_IDS:
        if cur in visited:
            # Cycle protection: malformed input shouldn't infinite-loop.
            break
        visited.add(cur)
        entry = folders.get(cur)
        if entry is None:
            # Parent ID points to something we don't know about. Could be a storage
            # node or a malformed dump. Stop walking.
            break
        parts.append(entry.name)
        if entry.parent_id == cur:
            break
        cur = entry.parent_id
    if not parts:
        return "/"
    return "/" + "/".join(reversed(parts))


def build_inventory(
    files_stdout: str,
    folders_stdout: str,
) -> Inventory:
    """Combine `mtp-files` and `mtp-folders` output into a path-resolved Inventory.

    Note: we deliberately do not try to identify a single "GARMIN root" folder.
    Garmin's MTP exposes data folders at the storage root on modern wrist devices
    (Instinct 3, fenix, etc.), and the literal `Garmin` folder that does exist on
    the Instinct 3 is the firmware/basemap folder, NOT the parent of user data.
    Categorization is performed per-file via `categorize()` walking the path
    components, which works for both layouts.
    """
    folders = parse_mtp_folders(folders_stdout)
    file_entries = parse_mtp_files(files_stdout)

    inv = Inventory(folders=folders)

    for fe in file_entries:
        # Skip directory entries — they're already in `folders` if mtp-files ever lists
        # them. The Garmin watch's `mtp-files` typically only emits real files, but be
        # defensive.
        if fe.filetype.lower() == "folder":
            continue
        parent_path = _resolve_path(folders, fe.parent_id)
        full_path = (
            parent_path.rstrip("/") + "/" + fe.filename
            if parent_path != "/"
            else "/" + fe.filename
        )
        category = categorize(parent_path)
        inv.files.append(
            ResolvedFile(
                file_id=fe.file_id,
                filename=fe.filename,
                size_bytes=fe.size_bytes,
                parent_path=parent_path,
                full_path=full_path,
                category=category,
            )
        )
    return inv


# ---- public façade ---------------------------------------------------------------------


def fetch_inventory(runner: MtpRunner) -> tuple[Inventory, str, str]:
    """Run `mtp-files` and `mtp-folders` and parse them into an Inventory.

    Returns the inventory plus the raw combined output of each tool, so the caller
    can dump them to logs on the next-step parse failure.

    Reads the combined stdout+stderr because libmtp's example tools split their
    output between streams in ways that vary across versions and devices.
    """
    files_result = runner.run("mtp-files", timeout=LONG_TIMEOUT_S)
    folders_result = runner.run("mtp-folders", timeout=LONG_TIMEOUT_S)
    files_text = files_result.combined
    folders_text = folders_result.combined
    inv = build_inventory(files_text, folders_text)
    return inv, files_text, folders_text
