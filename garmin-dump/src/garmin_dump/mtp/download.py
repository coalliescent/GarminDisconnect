"""mtp-getfile orchestration: temp+atomic-rename, streaming SHA-256, stale-ID retry."""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path

from garmin_dump.archive.hashing import sha256_file
from garmin_dump.errors import ArchiveError, MtpError, MtpFileNotFoundError
from garmin_dump.mtp.runner import LONG_TIMEOUT_S, MtpResult, MtpRunner

# libmtp prints these substrings (case-insensitive) when the file ID is invalid.
# Used by `is_stale_id_error` to decide whether to refresh inventory and retry.
_STALE_ID_MARKERS = (
    "could not get file",
    "not found",
    "invalid object",
    "no such",
)


@dataclass(frozen=True)
class DownloadResult:
    final_path: Path
    sha256: str
    size_bytes: int


def is_stale_id_error(result: MtpResult) -> bool:
    """Heuristic: did mtp-getfile fail because the file ID has been reassigned?"""
    if result.ok:
        return False
    haystack = (result.stderr + " " + result.stdout).lower()
    return any(marker in haystack for marker in _STALE_ID_MARKERS)


def download_file(
    runner: MtpRunner,
    *,
    file_id: int,
    expected_size: int,
    tmp_dir: Path,
    final_path: Path,
) -> DownloadResult:
    """Download a file by libmtp file ID, verify its size, hash it, atomic-rename.

    Raises:
        MtpFileNotFoundError if the file ID is stale (caller may retry after refreshing
            inventory).
        MtpError on any other libmtp failure.
        ArchiveError on local filesystem failures (size mismatch, atomic rename, …).
    """
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"{secrets.token_hex(8)}.partial"

    result = runner.run(
        "mtp-getfile",
        str(file_id),
        str(tmp_path),
        timeout=LONG_TIMEOUT_S,
    )
    if not result.ok:
        # Clean up any partial file before raising.
        _safe_unlink(tmp_path)
        if is_stale_id_error(result):
            raise MtpFileNotFoundError(
                f"mtp-getfile {file_id}: file ID appears stale "
                f"(stderr: {result.stderr.strip()})"
            )
        raise MtpError(
            f"mtp-getfile {file_id} exited {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip() or '<no output>'}"
        )

    if not tmp_path.exists():
        raise MtpError(f"mtp-getfile {file_id} succeeded but produced no file")

    actual_size = tmp_path.stat().st_size
    if actual_size != expected_size:
        _safe_unlink(tmp_path)
        raise ArchiveError(
            f"size mismatch for file ID {file_id}: expected {expected_size} bytes, "
            f"downloaded {actual_size} bytes"
        )

    digest = sha256_file(tmp_path)

    final_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(tmp_path, final_path)
    except OSError as e:
        _safe_unlink(tmp_path)
        raise ArchiveError(
            f"could not atomic-rename {tmp_path} -> {final_path}: {e}"
        ) from e

    return DownloadResult(
        final_path=final_path,
        sha256=digest,
        size_bytes=actual_size,
    )


def _safe_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass


def gc_tmp(tmp_dir: Path) -> int:
    """Delete all leftover .partial files from previous runs. Returns count."""
    if not tmp_dir.exists():
        return 0
    count = 0
    for entry in tmp_dir.iterdir():
        if entry.is_file() and entry.name.endswith(".partial"):
            _safe_unlink(entry)
            count += 1
    return count
