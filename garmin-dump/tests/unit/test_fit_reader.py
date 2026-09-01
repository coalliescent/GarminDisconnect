"""Tests for fit_reader's by_num indexing and helper functions.

These exercise the integer-keyed dispatch path that the sleep and monitoring
parsers use to handle Garmin's undocumented `unknown_NNN` messages. They also
serve as a regression guard: if a future fitdecode upgrade stops exposing
`def_num` on unknown-message fields, these tests will catch it.

Both fixtures are SYNTHETIC — see tests/fixtures/build_fit_fixtures.py.
"""

from __future__ import annotations

from pathlib import Path

from garmin_dump.ingest.fit_reader import (
    bucket_file,
    iter_messages_for_num,
    msg_num,
    raw_field_values,
)

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
SLEEP_FIXTURE = FIXTURES / "sleep_F5I94001.fit"
MONITOR_FIXTURE = FIXTURES / "monitor_M47N0648.FIT"


def test_sleep_fixture_exposes_target_globals_via_by_num() -> None:
    """The sleep fixture must contain all four target Instinct 3 sleep messages."""
    buckets = bucket_file(SLEEP_FIXTURE)
    # 273=sleep_data_info, 275=sleep_level, 346=sleep_assessment, 382=sleep_restless_moments
    for num in (273, 275, 346, 382):
        assert num in buckets.by_num, f"missing global {num} in by_num"
        assert len(buckets.by_num[num]) >= 1


def test_msg_num_handles_unknown_messages() -> None:
    """msg_num() must return the integer global mesg num for `unknown_NNN`
    messages, where fitdecode 0.10 doesn't know the name."""
    buckets = bucket_file(SLEEP_FIXTURE)
    # sleep_level (275) is the message we know is the most numerous in the fixture
    level_msgs = buckets.by_num.get(275, [])
    assert level_msgs, "fixture should have sleep_level messages"
    for msg in level_msgs:
        assert msg_num(msg) == 275


def test_raw_field_values_returns_def_num_keyed_dict() -> None:
    """raw_field_values must expose fields by integer def_num so handlers can
    pick out a specific field on an unknown_NNN message."""
    buckets = bucket_file(SLEEP_FIXTURE)
    msg = buckets.by_num[275][0]
    raw = raw_field_values(msg)
    assert isinstance(raw, dict)
    # sleep_level has f253 (timestamp) and f0 (stage enum). Both should be present.
    assert 253 in raw, f"def_num 253 missing from {raw.keys()}"
    assert 0 in raw, f"def_num 0 missing from {raw.keys()}"
    # Stage value must be in the documented enum range.
    stage = raw[0]
    assert isinstance(stage, int) and 0 <= stage <= 4


def test_iter_messages_for_num_yields_only_matching() -> None:
    """The streaming integer-num iterator should yield only messages whose
    global mesg num is in the requested set."""
    seen = set()
    for msg in iter_messages_for_num(MONITOR_FIXTURE, [297, 227]):
        n = msg_num(msg)
        seen.add(n)
        assert n in {297, 227}
    # The monitor fixture carries exactly these two message types (plus file_id).
    assert seen == {297, 227}, f"expected both 297 and 227, got {seen}"


def test_unknown_counts_indexed_by_num() -> None:
    """MessageBuckets.unknown_counts should also be keyed by integer mesg num
    (the existing behavior — verify it still works alongside by_num).

    fitdecode 0.11+ recognizes sleep_level (275) and sleep_assessment (346)
    by name, so they are NOT in unknown_counts even though they're in
    by_num. Only the still-undocumented messages (273, 382) end up here.
    """
    buckets = bucket_file(SLEEP_FIXTURE)
    for num in (273, 382):
        assert buckets.unknown_counts.get(num, 0) >= 1
