"""Tests for the case-insensitive remote-folder → category bucketing."""

from __future__ import annotations

from garmin_dump.archive.layout import Category, categorize


def test_activity_paths() -> None:
    assert categorize("/GARMIN/Activity") is Category.ACTIVITY
    assert categorize("/GARMIN/ACTIVITY") is Category.ACTIVITY
    assert categorize("/garmin/activities") is Category.ACTIVITY


def test_monitoring_paths_both_spellings() -> None:
    assert categorize("/GARMIN/Monitor") is Category.MONITOR
    assert categorize("/GARMIN/Monitoring") is Category.MONITOR
    assert categorize("/GARMIN/MONITORING") is Category.MONITOR


def test_sleep_paths() -> None:
    assert categorize("/GARMIN/Sleep") is Category.SLEEP
    assert categorize("/GARMIN/SLEEP") is Category.SLEEP


def test_metrics_paths() -> None:
    assert categorize("/GARMIN/Metrics") is Category.METRICS
    assert categorize("/garmin/metric") is Category.METRICS


def test_unknown_paths_bucket_as_other() -> None:
    assert categorize("/GARMIN/Settings") is Category.OTHER
    assert categorize("/GARMIN/Courses") is Category.OTHER
    assert categorize("/SOMETHING") is Category.OTHER
    assert categorize("/") is Category.OTHER
