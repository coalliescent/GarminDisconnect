"""Subprocess wrapper around the libmtp `mtp-*` command-line tools.

This is the only place that calls `subprocess.run` for libmtp tools. Everywhere else
goes through `MtpRunner.run(...)` so we have one chokepoint for:
    - PATH lookup (so a missing binary becomes ToolchainError, not FileNotFoundError)
    - timeouts
    - stderr capture (libmtp is noisy on stderr; we want it for diagnostics)
    - libmtp version sanity checks
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass

from garmin_dump.errors import LibmtpVersionError, ToolchainError

DEFAULT_TIMEOUT_S = 60.0
LONG_TIMEOUT_S = 600.0  # used by mtp-files / mtp-getfile on large devices

REQUIRED_TOOLS = (
    "mtp-detect",
    "mtp-files",
    "mtp-folders",
    "mtp-getfile",
    "mtp-delfile",
)

# Minimum libmtp version we trust the parsers against. Pinned to the Homebrew formula at
# the time the project was written; see plan.md "Open risks #1".
MIN_LIBMTP_VERSION = (1, 1, 21)


@dataclass(frozen=True)
class MtpResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    @property
    def combined(self) -> str:
        """stdout and stderr concatenated.

        libmtp's example tools split their output between stdout and stderr in ways
        that vary by tool, version, and which device is plugged in. The device header
        from `mtp-detect`, the file listing from `mtp-files`, and the folder tree
        from `mtp-folders` can all land on either stream. Our parsers always operate
        on the combined view because the line-format markers (`File ID:`, `Device 0
        (VID=...`, etc.) are unambiguous regardless of source stream.
        """
        if self.stdout and self.stderr:
            return self.stdout + "\n" + self.stderr
        return self.stdout or self.stderr


class MtpRunner:
    """Locate libmtp binaries on PATH and execute them."""

    def __init__(self) -> None:
        self._paths: dict[str, str] = {}

    def locate(self, tool: str) -> str:
        """Resolve a tool name to an absolute path. Cached."""
        if (cached := self._paths.get(tool)) is not None:
            return cached
        path = shutil.which(tool)
        if path is None:
            raise ToolchainError(
                f"required tool `{tool}` not found on PATH. Install libmtp via "
                f"`brew install libmtp`."
            )
        self._paths[tool] = path
        return path

    def check_all_tools(self) -> dict[str, str]:
        """Resolve every required tool. Returns the {name: path} map."""
        return {t: self.locate(t) for t in REQUIRED_TOOLS}

    def run(
        self,
        tool: str,
        *args: str,
        timeout: float = DEFAULT_TIMEOUT_S,
        check: bool = False,
    ) -> MtpResult:
        """Run a libmtp tool. Never raises on non-zero exit unless `check=True`."""
        path = self.locate(tool)
        try:
            proc = subprocess.run(
                [path, *args],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as e:
            raise ToolchainError(
                f"`{tool}` timed out after {timeout:.0f}s. The watch may be unresponsive "
                f"or another process is holding the MTP lock."
            ) from e
        result = MtpResult(
            args=[path, *args],
            returncode=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
        )
        if check and not result.ok:
            raise ToolchainError(
                f"`{tool}` exited with code {result.returncode}\n"
                f"stderr: {result.stderr.strip()}"
            )
        return result

    # ---- libmtp version sanity check --------------------------------------------------

    def libmtp_version(self) -> tuple[int, int, int]:
        """Read libmtp's version from `mtp-detect`. Raises if it can't be parsed."""
        result = self.run("mtp-detect", timeout=10.0)
        # mtp-detect prints something like "libmtp version: 1.1.21" near the top.
        # We tolerate either stdout or stderr placement.
        text = (result.stdout or "") + "\n" + (result.stderr or "")
        match = re.search(r"libmtp version[:\s]+(\d+)\.(\d+)\.(\d+)", text, re.I)
        if match is None:
            raise LibmtpVersionError(
                "could not parse libmtp version from `mtp-detect` output. "
                "Is libmtp installed and on PATH?"
            )
        return (int(match.group(1)), int(match.group(2)), int(match.group(3)))

    def assert_libmtp_supported(self) -> tuple[int, int, int]:
        version = self.libmtp_version()
        if version < MIN_LIBMTP_VERSION:
            min_str = ".".join(str(x) for x in MIN_LIBMTP_VERSION)
            cur_str = ".".join(str(x) for x in version)
            raise LibmtpVersionError(
                f"libmtp {cur_str} is older than the minimum supported version "
                f"{min_str}. Run `brew upgrade libmtp`."
            )
        return version
