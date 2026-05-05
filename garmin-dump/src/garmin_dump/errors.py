"""Typed exceptions used throughout garmin-dump.

Every error the user might see should derive from `GarminDumpError`. Operational errors
that should produce a clean non-zero exit (rather than a stack trace) are caught at the
CLI boundary in `cli.py`.
"""

from __future__ import annotations


class GarminDumpError(Exception):
    """Base class for all garmin-dump errors."""


# --- Toolchain / environment ------------------------------------------------------------


class ToolchainError(GarminDumpError):
    """A required external tool is missing or unusable (e.g. libmtp)."""


class LibmtpVersionError(ToolchainError):
    """libmtp is present but the version is too old or unparseable."""


# --- MTP transport ----------------------------------------------------------------------


class MtpError(GarminDumpError):
    """Generic MTP failure (subprocess error, libmtp panic, …)."""


class DeviceBusyError(MtpError):
    """Another process is holding the MTP device (Garmin Express, Image Capture, …)."""

    def __init__(self, holders: list[str]) -> None:
        self.holders = holders
        joined = ", ".join(holders) if holders else "<unknown>"
        super().__init__(
            f"MTP device appears to be held by another process: {joined}. "
            f"Quit these apps (cmd-Q) and any background daemons before retrying. "
            f"Never use `kill -9` for this — let them exit cleanly."
        )


class DeviceNotFoundError(MtpError):
    """`mtp-detect` returned no compatible Garmin device."""


class MtpOutputParseError(MtpError):
    """libmtp tool output didn't match the expected format.

    Carries the raw stdout so the caller can dump it to a log file for forensics.
    """

    def __init__(self, tool: str, message: str, raw_output: str) -> None:
        self.tool = tool
        self.raw_output = raw_output
        super().__init__(f"failed to parse output of `{tool}`: {message}")


class MtpFileNotFoundError(MtpError):
    """`mtp-getfile` reported the file ID is no longer valid (stale ID)."""


# --- Device identity --------------------------------------------------------------------


class GarminXmlError(GarminDumpError):
    """`GarminDevice.xml` couldn't be located or parsed on the device."""


# --- Archive / database -----------------------------------------------------------------


class ArchiveError(GarminDumpError):
    """Filesystem-level archive failure (path not writable, atomic rename failed, …)."""


class HashMismatchError(ArchiveError):
    """A file's recomputed SHA256 disagrees with the value in `sync_log`."""


class DatabaseError(GarminDumpError):
    """SQLite migration or query failure."""


class SchemaVersionError(DatabaseError):
    """The on-disk schema version is newer than this binary understands."""


# --- Ingest -----------------------------------------------------------------------------


class IngestError(GarminDumpError):
    """Generic ingest failure. Per-file errors are logged + skipped, not raised."""
