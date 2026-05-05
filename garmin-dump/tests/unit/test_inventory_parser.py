"""Regression tests for the libmtp `mtp-files` and `mtp-folders` parsers.

These are the safety net for the highest-risk file in the project. The fixture text
is modeled on real Instinct 3 - 45mm output (libmtp 1.1.23, 2026 macOS), which
exposes user-data folders directly under the storage root rather than nested under
a GARMIN folder. If a libmtp upgrade ever changes the output format, these tests
will fail and force a deliberate parser update before any user runs `pull`.
"""

from __future__ import annotations

from pathlib import Path

from garmin_dump.archive.layout import Category
from garmin_dump.mtp.inventory import (
    build_inventory,
    parse_mtp_files,
    parse_mtp_folders,
)

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
FILES_TXT = FIXTURES / "mtp_files_sample.txt"
FOLDERS_TXT = FIXTURES / "mtp_folders_sample.txt"


def test_parse_mtp_files_known_fixture() -> None:
    entries = parse_mtp_files(FILES_TXT.read_text())
    by_id = {e.file_id: e for e in entries}
    # Spot-check a few of the larger entries
    assert 16777400 in by_id  # activity
    assert by_id[16777400].filename == "2025-04-13-11-43-30.fit"
    assert by_id[16777400].size_bytes == 81920
    assert by_id[16777400].parent_id == 16777233

    assert 16777500 in by_id  # monitor
    assert by_id[16777500].filename == "M24A3800.FIT"
    assert by_id[16777500].parent_id == 16777242

    # GarminDevice.xml lives at the storage root (parent_id = 0)
    assert 16778100 in by_id
    assert by_id[16778100].filename == "GarminDevice.xml"
    assert by_id[16778100].parent_id == 0


def test_parse_mtp_folders_known_fixture() -> None:
    folders = parse_mtp_folders(FOLDERS_TXT.read_text())
    names = {f.name for f in folders.values()}
    assert {"Garmin", "Activity", "Monitor", "Sleep", "Metrics", "HRVStatus"} <= names
    # On the Instinct 3 every folder lives at the storage root, parent_id 0.
    for f in folders.values():
        assert f.parent_id == 0
        assert f.depth == 0


def test_build_inventory_resolves_top_level_paths() -> None:
    inv = build_inventory(FILES_TXT.read_text(), FOLDERS_TXT.read_text())

    by_filename = {f.filename: f for f in inv.files}

    activity = by_filename["2025-04-13-11-43-30.fit"]
    assert activity.parent_path == "/Activity"
    assert activity.full_path == "/Activity/2025-04-13-11-43-30.fit"
    assert activity.category is Category.ACTIVITY

    monitor = by_filename["M24A3800.FIT"]
    assert monitor.parent_path == "/Monitor"
    assert monitor.category is Category.MONITOR

    sleep = by_filename["F4D90308.fit"]
    assert sleep.parent_path == "/Sleep"
    assert sleep.category is Category.SLEEP

    metrics = by_filename["G3D00206.fit"]
    assert metrics.parent_path == "/Metrics"
    assert metrics.category is Category.METRICS


def test_hrvstatus_buckets_as_monitor() -> None:
    """HRVStatus is continuous wellness telemetry — fold it into the monitor
    category so it shares the wellness_samples / wellness_daily storage path."""
    inv = build_inventory(FILES_TXT.read_text(), FOLDERS_TXT.read_text())
    hrv = next(f for f in inv.files if f.parent_path == "/HRVStatus")
    assert hrv.category is Category.MONITOR


def test_settings_and_basemap_bucket_as_other() -> None:
    inv = build_inventory(FILES_TXT.read_text(), FOLDERS_TXT.read_text())
    settings = next(f for f in inv.files if f.filename == "Settings.fit")
    assert settings.parent_path == "/Settings"
    assert settings.category is Category.OTHER

    basemap = next(f for f in inv.files if f.filename == "gmaptz.img")
    assert basemap.parent_path == "/Garmin"
    assert basemap.category is Category.OTHER  # firmware folder, not user data


def test_storage_root_files_resolve_correctly() -> None:
    """Files whose parent_id is 0 (the storage root, not any folder) should
    resolve to a path of `/<filename>`."""
    inv = build_inventory(FILES_TXT.read_text(), FOLDERS_TXT.read_text())
    xml = next(f for f in inv.files if f.filename == "GarminDevice.xml")
    assert xml.parent_path == "/"
    assert xml.full_path == "/GarminDevice.xml"
