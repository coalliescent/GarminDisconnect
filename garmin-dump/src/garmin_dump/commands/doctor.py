"""`garmin-dump doctor` — preflight environment checks.

Each check produces a row in a Rich table. The command exits non-zero if any
**required** check fails. "Device detected" is informational only — running doctor
without a watch plugged in should still succeed.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from rich.console import Console
from rich.table import Table

from garmin_dump.config import Config, ensure_dirs
from garmin_dump.db.connection import Database
from garmin_dump.db.migrations import CURRENT_VERSION, get_user_version
from garmin_dump.errors import (
    DeviceBusyError,
    DeviceNotFoundError,
    GarminDumpError,
    LibmtpVersionError,
    ToolchainError,
)
from garmin_dump.mtp.detect import detect_garmin, find_lock_holders
from garmin_dump.mtp.runner import REQUIRED_TOOLS, MtpRunner


class CheckStatus(StrEnum):
    OK = "ok"
    INFO = "info"
    FAIL = "fail"


@dataclass
class CheckResult:
    name: str
    status: CheckStatus
    detail: str


def run_doctor(cfg: Config, *, console: Console | None = None) -> int:
    """Run all preflight checks. Returns the exit code (0 = green)."""
    console = console or Console()
    runner = MtpRunner()
    results: list[CheckResult] = []

    # 1. libmtp tools on PATH
    try:
        paths = runner.check_all_tools()
        results.append(
            CheckResult(
                "libmtp tools",
                CheckStatus.OK,
                f"{len(paths)}/{len(REQUIRED_TOOLS)} tools found",
            )
        )
    except ToolchainError as e:
        results.append(CheckResult("libmtp tools", CheckStatus.FAIL, str(e)))

    # 2. libmtp version
    try:
        version = runner.assert_libmtp_supported()
        results.append(
            CheckResult(
                "libmtp version",
                CheckStatus.OK,
                ".".join(str(x) for x in version),
            )
        )
    except (LibmtpVersionError, ToolchainError) as e:
        results.append(CheckResult("libmtp version", CheckStatus.FAIL, str(e)))

    # 3. MTP lock holders (informational only — see note below)
    #
    # Empirically, libmtp 1.1.23 on Sequoia/Tahoe coexists fine with icdd,
    # cameracaptured, photolibraryd and friends for the Garmin Instinct 3 — the
    # exclusive-USB-lock conventional wisdom from old forum posts simply doesn't
    # apply to this device class in 2026 macOS. So we list potential lock holders
    # as a hint (in case mtp-detect later fails) but never as a hard failure.
    hits = find_lock_holders()
    if hits:
        lines = ["potential lock holders running (usually harmless):"]
        for h in hits:
            pids = ",".join(str(p) for p in h.pids)
            lines.append(f"  • {h.rule.label} (pid {pids})")
        results.append(
            CheckResult("MTP lock holders", CheckStatus.INFO, "\n".join(lines))
        )
    else:
        results.append(
            CheckResult(
                "MTP lock holders",
                CheckStatus.OK,
                "no Garmin Express / icdd / cameracaptured / etc. detected",
            )
        )

    # 4. Archive directory writable
    try:
        ensure_dirs(cfg)
        results.append(
            CheckResult(
                "archive root",
                CheckStatus.OK,
                f"{cfg.archive_root} (writable)",
            )
        )
    except OSError as e:
        results.append(CheckResult("archive root", CheckStatus.FAIL, f"{cfg.archive_root}: {e}"))

    # 5. SQLite database migrations
    try:
        with Database(cfg.db_path) as db:
            v = get_user_version(db.conn)
            results.append(
                CheckResult(
                    "database",
                    CheckStatus.OK,
                    f"{cfg.db_path} (schema v{v}, latest v{CURRENT_VERSION})",
                )
            )
    except GarminDumpError as e:
        results.append(CheckResult("database", CheckStatus.FAIL, str(e)))

    # 6. Device detection (informational)
    try:
        device = detect_garmin(runner)
        results.append(
            CheckResult(
                "device detected",
                CheckStatus.OK,
                f"{device.product} (vendor={device.vendor}, vid={device.vendor_id}, "
                f"pid={device.product_id})",
            )
        )
    except DeviceBusyError as e:
        results.append(CheckResult("device detected", CheckStatus.FAIL, str(e)))
    except (DeviceNotFoundError, ToolchainError) as e:
        results.append(
            CheckResult(
                "device detected",
                CheckStatus.INFO,
                f"no device (this is OK if the watch isn't plugged in): {e}",
            )
        )

    _render(console, results)
    return 0 if not any(r.status is CheckStatus.FAIL for r in results) else 2


def _render(console: Console, results: list[CheckResult]) -> None:
    table = Table(title="garmin-dump doctor", show_header=True, header_style="bold")
    table.add_column("check", style="bold")
    table.add_column("status")
    table.add_column("detail")
    for r in results:
        style = {
            CheckStatus.OK: "green",
            CheckStatus.INFO: "yellow",
            CheckStatus.FAIL: "red",
        }[r.status]
        table.add_row(r.name, f"[{style}]{r.status}[/{style}]", r.detail)
    console.print(table)
