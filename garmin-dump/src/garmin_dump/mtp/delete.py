"""mtp-delfile wrapper."""

from __future__ import annotations

from garmin_dump.errors import MtpError
from garmin_dump.mtp.runner import MtpRunner


def delete_file(runner: MtpRunner, file_id: int) -> None:
    """Delete a file from the device by libmtp file ID. Raises on failure."""
    result = runner.run("mtp-delfile", "-n", str(file_id), timeout=30.0)
    if not result.ok:
        raise MtpError(
            f"mtp-delfile {file_id} exited {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip() or '<no output>'}"
        )
