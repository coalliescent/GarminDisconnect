"""Regression tests for the `wellness_daily` rollup of `monitoring` (g=55).

These tests build REAL FIT files and push them through `ingest_monitoring`, so
fitdecode does the decoding the production path relies on. That matters more
than it looks: the bugs this module guards against all live in the gap between
"what the field is called" and "what the decoder hands you".

The FIT profile facts under test (from `fitdecode.profile.MESSAGE_TYPES[55]`):

    f3  cycles                    scale 2
          +-- subfield `steps`    scale 1   when activity_type in (walking, running)
          +-- subfield `strokes`  scale 2   when activity_type in (cycling, swimming)
    f1  calories / f2 distance (scale 100) / f19 active_calories
        -- all "Accumulated ... Maintained for each activity_type"
    f24 current_activity_type_intensity -> expands to (activity_type, intensity)
    f29 duration_min

So a day's total is the sum across activity types of the high-water mark within
each, and only walking/running rows carry steps. A duck-typed fake message
cannot exercise any of that, which is why these build real blobs.
"""

from __future__ import annotations

import struct
from datetime import UTC, datetime, timedelta

import pytest
from build_fit_fixtures import fit_crc
from monitor_builder import (
    ALL,
    CYCLING,
    GENERIC,
    LOCAL_OFFSET_S,
    RUNNING,
    SEDENTARY,
    SWIMMING,
    WALKING,
    MonitorFile,
)

from tests.unit.conftest import MonitorHarness

# ---- the decoder's own behaviour ---------------------------------------------------------


def test_profile_says_steps_is_a_scale_2_subfield_of_cycles() -> None:
    """Pins the profile facts the rollup is built on.

    If a fitdecode upgrade changed any of these, every assertion below would
    still pass while silently measuring something else.
    """
    import fitdecode.profile as profile

    cycles = profile.MESSAGE_TYPES[55].fields[3]
    assert cycles.name == "cycles"
    assert cycles.scale == 2, "f3 base field is scale 2 (raw value == steps, scaled == strides)"
    by_name = {sf.name: sf for sf in cycles.subfields}
    assert by_name["steps"].scale is None, "`steps` subfield is unscaled"
    assert {(r.name, r.value) for r in by_name["steps"].ref_fields} == {
        ("activity_type", "walking"),
        ("activity_type", "running"),
    }
    assert {(r.name, r.value) for r in by_name["strokes"].ref_fields} == {
        ("activity_type", "cycling"),
        ("activity_type", "swimming"),
    }
    assert "floors_climbed" not in {f.name for f in profile.MESSAGE_TYPES[55].fields.values()}


def test_cycles_and_steps_are_the_same_field_on_a_walking_row(
    monitor: MonitorHarness,
) -> None:
    """`get_value("cycles")` returns the STEP count on a walking row.

    `FieldData.is_named` matches the parent field as well as the subfield, so
    both names resolve to one field — which is why reading `cycles` as steps
    looked right on walking rows and was wrong everywhere else. It also means
    the sample extractor must not write the value twice.
    """
    import fitdecode

    tmp_path = monitor.tmp_path
    path = MonitorFile().snapshot(
        "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
    ).write(tmp_path / "walk.FIT")

    with fitdecode.FitReader(str(path)) as fr:
        msgs = [m for m in fr if isinstance(m, fitdecode.FitDataMessage) and m.name == "monitoring"]
    assert len(msgs) == 1
    msg = msgs[0]
    assert msg.get_value("steps") == 25966
    assert msg.get_value("cycles") == 25966, "same physical field, so the same value"
    assert [f.name for f in msg.fields].count("steps") == 1
    assert "cycles" not in [f.name for f in msg.fields], "resolved to the subfield name"


def test_cycles_is_half_the_steps_when_activity_type_is_not_a_step_type(
    monitor: MonitorHarness,
) -> None:
    """On a generic row the same raw f3 decodes as scale-2 `cycles` — half.

    This is the trap: a naive `steps or cycles` fallback reads 12,983 here and
    25,966 on the walking row above, from identical bytes.
    """
    import fitdecode

    tmp_path = monitor.tmp_path
    path = MonitorFile().snapshot(
        "2026-09-10T07:00", GENERIC, steps=25966, duration_min=1440
    ).write(tmp_path / "generic.FIT")

    with fitdecode.FitReader(str(path)) as fr:
        msg = next(
            m for m in fr if isinstance(m, fitdecode.FitDataMessage) and m.name == "monitoring"
        )
    assert msg.get_value("cycles") == 12983.0
    assert msg.get_value("steps", fallback=None) is None


# ---- cumulative vs summed ----------------------------------------------------------------


def test_repeated_snapshots_of_one_day_are_not_summed(monitor: MonitorHarness) -> None:
    """The 2026-09-11 file re-emitted the same day three times (dur 1239/1241/1254).

    walking 14,315 + running 23 == 14,338 steps. The old SUM reported 28,676.
    """
    mf = MonitorFile()
    for dur in (1239, 1241, 1254):
        stamp = f"2026-09-12T0{3}:{dur - 1200:02d}"
        mf.snapshot(stamp, WALKING, steps=14315, duration_min=dur)
        mf.snapshot(stamp, RUNNING, steps=23, duration_min=dur)
    monitor.ingest("M9BK5411.FIT", mf)

    row = monitor.day("2026-09-11")
    assert row is not None, f"no row for 2026-09-11, have {monitor.all_days()}"
    assert row["steps"] == 14338, (
        f"steps={row['steps']}: accumulated snapshots are being summed instead of "
        "taking the high-water mark per activity_type"
    )


def test_distance_and_calories_are_high_water_marks_too(
    monitor: MonitorHarness,
) -> None:
    """The same `+=` bug doubled distance/active_kcal, plotted beside steps."""
    mf = MonitorFile()
    for dur in (1241, 1254):
        mf.snapshot(
            f"2026-09-12T03:{dur - 1200:02d}",
            WALKING,
            steps=14315,
            distance_m=14781.73,
            active_calories=777,
            calories=2400,
            duration_min=dur,
        )
    monitor.ingest("M9BK3953.FIT", mf)

    row = monitor.day("2026-09-11")
    assert row["distance_m"] == pytest.approx(14781.73)
    assert row["active_kcal"] == 777
    assert row["bmr_kcal"] == 2400 - 777


def test_activity_types_add_up_within_one_day(monitor: MonitorHarness) -> None:
    """High-water marks are per activity_type; the day adds the types together."""
    mf = (
        MonitorFile()
        .snapshot("2026-09-09T18:00", WALKING, steps=1000, duration_min=660)
        .snapshot("2026-09-09T18:00", RUNNING, steps=200, duration_min=660)
    )
    monitor.ingest("M9X00000.FIT", mf)
    assert monitor.day("2026-09-09")["steps"] == 1200


def test_intensity_minutes_are_not_tripled_by_re_emission(
    monitor: MonitorHarness,
) -> None:
    """Intensity minutes ride along in the same re-emitted messages.

    Summing them tripled the day exactly as it tripled steps. 30 moderate +
    2 * 10 vigorous == 50.
    """
    mf = MonitorFile()
    for dur in (1239, 1241, 1254):
        mf.snapshot(
            f"2026-09-12T03:{dur - 1200:02d}",
            WALKING,
            moderate_min=30,
            vigorous_min=10,
            duration_min=dur,
        )
    monitor.ingest("M9BK5411.FIT", mf)
    assert monitor.day("2026-09-11")["intensity_min"] == 50


# ---- which rows may contribute steps -----------------------------------------------------


def test_generic_rows_never_contribute_steps(monitor: MonitorHarness) -> None:
    """f3 on a generic row is an undifferentiated cycle count, not steps.

    Counting it would both double the day (if generic mirrors the total) and do
    so at half scale. 1,000 walked + 200 run is 1,200 no matter what the
    generic row claims.
    """
    mf = (
        MonitorFile()
        .snapshot("2026-09-09T18:00", WALKING, steps=1000, duration_min=660)
        .snapshot("2026-09-09T18:00", RUNNING, steps=200, duration_min=660)
        .snapshot("2026-09-09T18:00", GENERIC, steps=1200, duration_min=660)
    )
    monitor.ingest("M9G00000.FIT", mf)
    assert monitor.day("2026-09-09")["steps"] == 1200


def test_cycling_strokes_are_never_counted_as_steps(monitor: MonitorHarness) -> None:
    """f3 on a cycling row decodes as `strokes`. A bike ride is not 9,000 steps."""
    mf = (
        MonitorFile()
        .snapshot("2026-09-09T18:00", WALKING, steps=5000, duration_min=660)
        .snapshot("2026-09-09T18:00", CYCLING, steps=9000, duration_min=660)
        .snapshot("2026-09-09T18:00", SWIMMING, steps=4000, duration_min=660)
    )
    monitor.ingest("M9C00000.FIT", mf)
    assert monitor.day("2026-09-09")["steps"] == 5000


def test_aggregate_activity_type_does_not_double_the_day(
    monitor: MonitorHarness,
) -> None:
    """`all` (enum 254) is a cross-type aggregate; adding it would double."""
    mf = (
        MonitorFile()
        .snapshot("2026-09-09T18:00", WALKING, steps=1000, distance_m=800.0, duration_min=660)
        .snapshot("2026-09-09T18:00", ALL, steps=1000, distance_m=800.0, duration_min=660)
    )
    monitor.ingest("M9L00000.FIT", mf)
    row = monitor.day("2026-09-09")
    assert row["steps"] == 1000
    assert row["distance_m"] == pytest.approx(800.0)


def test_packed_activity_type_still_yields_the_right_step_count(
    monitor: MonitorHarness,
) -> None:
    """activity_type via f24 leaves f3 unresolved, so `cycles` needs doubling.

    fitdecode cannot dispatch a subfield off an expanded component, so a
    walking row whose activity_type arrives packed exposes only `cycles` at
    scale 2. Reading it verbatim halves the day.
    """
    mf = MonitorFile().snapshot(
        "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440, packed_intensity=2
    )
    monitor.ingest("M9P00000.FIT", mf)
    assert monitor.day("2026-09-09")["steps"] == 25966


# ---- day attribution ---------------------------------------------------------------------


def test_end_of_day_snapshot_belongs_to_the_day_that_ended(
    monitor: MonitorHarness,
) -> None:
    """A 1440-minute window stamped at local midnight covers the PREVIOUS day."""
    mf = MonitorFile().snapshot(
        "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
    )
    monitor.ingest("M9B00000.FIT", mf)
    assert monitor.all_days() == ["2026-09-09"], (
        "end-of-day snapshot landed on the day that started at that instant; "
        "every daily total would shift forward by one day"
    )
    assert monitor.day("2026-09-09")["steps"] == 25966


def test_partial_day_snapshot_stays_on_its_own_day(monitor: MonitorHarness) -> None:
    """Counterpart to the midnight case: 67 steps at 09:24 local is still 09-08."""
    mf = MonitorFile().snapshot(
        "2026-09-08T16:24", WALKING, steps=67, duration_min=564
    )
    monitor.ingest("M9900000.FIT", mf)
    assert monitor.all_days() == ["2026-09-08"], f"have {monitor.all_days()}"
    assert monitor.day("2026-09-08")["steps"] == 67


@pytest.mark.parametrize("duration_min", [1, 15, 120, 720, 1439, 1440])
def test_midnight_anchored_windows_always_land_on_their_own_day(
    monitor: MonitorHarness, duration_min: int
) -> None:
    """The midpoint rule is exact for every window that starts at local midnight.

    Window == [midnight, midnight + duration], stamped at its end, so the
    midpoint is midnight + duration/2 — inside the day for any duration <= 1440.
    """
    # 07:00 UTC on the 9th IS local midnight opening 2026-09-09, so every
    # window anchored there belongs to the 9th however long it runs.
    end_utc = datetime(2026, 9, 9, 7, 0, tzinfo=UTC) + timedelta(minutes=duration_min)
    mf = MonitorFile().snapshot(
        end_utc.strftime("%Y-%m-%dT%H:%M"), WALKING, steps=500, duration_min=duration_min
    )
    monitor.ingest("M9W00000.FIT", mf)
    assert monitor.all_days() == ["2026-09-09"], f"duration={duration_min} landed on {monitor.all_days()}"


# ---- cross-file merge --------------------------------------------------------------------


def test_a_later_smaller_file_must_not_clobber_the_day(
    monitor: MonitorHarness,
) -> None:
    """2026-09-09: full-day 25,966 in one file, a 242-step partial in another.

    The old `steps = excluded.steps` let whichever landed last win, so the day
    reported the smaller number. That collapse cost more than the inflation did.
    """
    monitor.ingest("M9A00000.FIT",
        MonitorFile().snapshot(
            "2026-09-09T16:02", WALKING, steps=242, duration_min=542
        ),
    )
    monitor.ingest("M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
        ),
    )
    assert monitor.day("2026-09-09")["steps"] == 25966


def test_day_total_is_independent_of_file_processing_order(
    monitor: MonitorHarness,
) -> None:
    """Same two files, reverse order, same answer. Nothing may depend on luck."""
    monitor.ingest("M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
        ),
    )
    monitor.ingest("M9A00000.FIT",
        MonitorFile().snapshot(
            "2026-09-09T16:02", WALKING, steps=242, duration_min=542
        ),
    )
    assert monitor.day("2026-09-09")["steps"] == 25966


def test_a_file_with_no_step_data_does_not_erase_the_day(
    monitor: MonitorHarness,
) -> None:
    """Exercises the `WHEN excluded.steps IS NULL THEN wellness_daily.steps` arm.

    A monitor file covering the same day with only HR in it must leave the
    totals alone rather than NULL them out.
    """
    monitor.ingest("M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, distance_m=19000.0, duration_min=1440
        ),
    )
    monitor.ingest("M9H00000.FIT",
        MonitorFile().snapshot("2026-09-09T20:00", SEDENTARY, heart_rate=58),
    )
    row = monitor.day("2026-09-09")
    assert row["steps"] == 25966
    assert row["distance_m"] == pytest.approx(19000.0)


# ---- columns with no source --------------------------------------------------------------


def test_floors_climbed_is_null_because_fit_has_no_such_field(
    monitor: MonitorHarness,
) -> None:
    """Documented dead column: nothing in the profile can populate it."""
    monitor.ingest("M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
        ),
    )
    assert monitor.day("2026-09-09")["floors_climbed"] is None


# ---- wellness_samples --------------------------------------------------------------------


def test_steps_are_not_written_to_wellness_samples_twice(
    monitor: MonitorHarness,
) -> None:
    """`cycles` and `steps` name one field, so they must yield one sample.

    Listing both meant anything summing sample metrics counted a walking row's
    steps double.
    """
    monitor.ingest("M9B00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
        ),
    )
    assert monitor.samples("steps") == [25966.0]
    assert monitor.samples("cycles") == [], "f3 was recorded twice under two names"


def test_generic_rows_record_their_cycles_sample_under_the_resolved_name(
    monitor: MonitorHarness,
) -> None:
    """A non-step row still gets its f3 sample, named `cycles` as decoded."""
    monitor.ingest("M9G00000.FIT",
        MonitorFile().snapshot(
            "2026-09-10T07:00", GENERIC, steps=25966, duration_min=1440
        ),
    )
    assert monitor.samples("cycles") == [12983.0]
    assert monitor.samples("steps") == []


# ---- premise check -----------------------------------------------------------------------


def test_local_offset_premise() -> None:
    """Sanity check on the fixtures' own premise: 07:00 UTC is local midnight."""
    midnight_local = datetime(2026, 9, 10, 7, 0, tzinfo=UTC) + timedelta(seconds=LOCAL_OFFSET_S)
    assert (midnight_local.hour, midnight_local.minute) == (0, 0)


def test_fit_writer_emits_a_crc_valid_file(monitor: MonitorHarness) -> None:
    """Guards the harness itself: a silently-corrupt blob would fail open.

    fitdecode skips what it can't parse, so a broken builder would make every
    rollup assertion above vacuous on an empty message stream.
    """
    tmp_path = monitor.tmp_path
    path = MonitorFile().snapshot(
        "2026-09-10T07:00", WALKING, steps=25966, duration_min=1440
    ).write(tmp_path / "crc.FIT")
    blob = path.read_bytes()

    body_len = 14 + struct.unpack("<I", blob[4:8])[0]
    assert fit_crc(blob[:body_len]) == struct.unpack("<H", blob[body_len : body_len + 2])[0]
