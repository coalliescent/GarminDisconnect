"""On-disk archive path conventions.

Layout:
    <archive_root>/
        garmin.db
        devices/<serial>/
            GarminDevice.xml
            device.json
            Activity/
            Monitor/
            Sleep/
            Metrics/
            _full/<relative path under /GARMIN/>
        tmp/<pid>/
        logs/

The category dirs are case-normalized: regardless of whether the device exposes
`Monitor`, `Monitoring`, or `MONITORING`, we always write to `Monitor/`.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

ARCHIVE_DIRNAME = "garmin-archive"
DEVICES_DIRNAME = "devices"
TMP_DIRNAME = "tmp"
LOGS_DIRNAME = "logs"
DB_FILENAME = "garmin.db"
GARMIN_DEVICE_XML = "GarminDevice.xml"
DEVICE_JSON = "device.json"


class Category(StrEnum):
    """Bucket assigned to each remote file. Persisted into `sync_log.category`."""

    ACTIVITY = "activity"
    MONITOR = "monitor"
    SLEEP = "sleep"
    METRICS = "metrics"
    OTHER = "other"


# Local directory name per category. `OTHER` files go under `_full/` only when
# `--full` is in effect.
CATEGORY_DIRNAME: dict[Category, str] = {
    Category.ACTIVITY: "Activity",
    Category.MONITOR: "Monitor",
    Category.SLEEP: "Sleep",
    Category.METRICS: "Metrics",
    Category.OTHER: "_full",
}


# Case-insensitive remote folder names that map to each category. The check is done by
# walking the path components (not just the immediate parent) so that e.g.
# `/GARMIN/Monitor/2026/04/foo.fit` still buckets as MONITOR.
#
# `hrvstatus` is folded into the monitor category because it's continuous wellness
# telemetry (heart-rate variability summaries written periodically). Adding it as a
# separate category would force a schema change for what is essentially the same
# kind of data the wellness_samples / wellness_daily tables already hold.
CATEGORY_FOLDER_HINTS: dict[Category, frozenset[str]] = {
    Category.ACTIVITY: frozenset({"activity", "activities"}),
    Category.MONITOR: frozenset({"monitor", "monitoring", "hrvstatus"}),
    Category.SLEEP: frozenset({"sleep"}),
    Category.METRICS: frozenset({"metrics", "metric"}),
}


def categorize(remote_parent: str) -> Category:
    """Pick a category from a remote path like `/GARMIN/Monitor`. Case-insensitive."""
    parts = [p.lower() for p in remote_parent.strip("/").split("/") if p]
    for cat, hints in CATEGORY_FOLDER_HINTS.items():
        if any(p in hints for p in parts):
            return cat
    return Category.OTHER


@dataclass(frozen=True)
class DeviceArchive:
    """Resolves on-disk paths for a single device."""

    archive_root: Path
    serial: str

    @property
    def dir(self) -> Path:
        return self.archive_root / DEVICES_DIRNAME / self.serial

    @property
    def garmin_xml_path(self) -> Path:
        return self.dir / GARMIN_DEVICE_XML

    @property
    def device_json_path(self) -> Path:
        return self.dir / DEVICE_JSON

    def category_dir(self, category: Category) -> Path:
        return self.dir / CATEGORY_DIRNAME[category]

    def file_path(
        self,
        category: Category,
        filename: str,
        *,
        full_relative: str | None = None,
    ) -> Path:
        """Compute the destination path for a downloaded file.

        For OTHER (under --full), `full_relative` is the path under /GARMIN/ so we can
        mirror the device structure beneath `_full/`.
        """
        if category is Category.OTHER:
            if full_relative is None:
                return self.category_dir(category) / filename
            return self.category_dir(category) / full_relative.lstrip("/")
        return self.category_dir(category) / filename

    def ensure_dirs(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)


def relative_to_archive(archive_root: Path, path: Path) -> str:
    """Return `path` as a string relative to `archive_root`. Stored in sync_log."""
    return str(path.resolve().relative_to(archive_root.resolve()))
