"""Builds real `monitoring` FIT files for the wellness rollup tests.

Shared by `test_monitoring_rollup.py` and `test_wellness_reparse.py`.

These tests deliberately build genuine FIT blobs and let fitdecode decode them
rather than using duck-typed fake messages. The bugs the rollup guards against
all live in the gap between what a field is *called* and what the decoder hands
back — `monitoring.steps` is a subfield of `cycles` with a different scale
factor, and which of the two you get depends on the message's `activity_type`
and on whether that arrived as its own field or packed into f24. A fake message
object cannot reproduce any of that, so it cannot catch a mistake about it.
"""

from __future__ import annotations

import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_fit_fixtures import (
    ENUM,
    UINT8,
    UINT16,
    UINT32,
    FitWriter,
    fit_ts,
)

# America/Los_Angeles in September: 07:00 UTC is local midnight, which is
# exactly where the end-of-day snapshots land.
LOCAL_OFFSET_S = -7 * 3600

# The local midnight every builder anchors its `monitoring_info` to.
LOCAL_MIDNIGHT_UTC = datetime(2026, 9, 10, 7, 0, tzinfo=UTC)

# activity_type enum values (FIT profile `activity_type`).
GENERIC = 0
RUNNING = 1
CYCLING = 2
SWIMMING = 5
WALKING = 6
SEDENTARY = 8
ALL = 254


class MonitorFile:
    """Accumulates `monitoring` messages, then writes a complete FIT file.

    Each `snapshot()` emits its own definition message listing exactly the
    fields that snapshot carries, which is how real files behave when the field
    set varies between messages — and it is what makes the f5-versus-f24
    activity_type distinction reachable.
    """

    def __init__(self, *, local_midnight_utc: datetime = LOCAL_MIDNIGHT_UTC) -> None:
        self._w = FitWriter()
        # file_id, type 32 = monitoring_b
        local = self._w.define(
            0, [(0, ENUM, 1), (1, UINT16, 1), (2, UINT16, 1), (3, UINT32, 1), (4, UINT32, 1)]
        )
        self._w.data(
            local,
            [
                (ENUM, 32),
                (UINT16, 1),
                (UINT16, 4443),
                (UINT32, 3509067685),
                (UINT32, fit_ts(local_midnight_utc)),
            ],
        )
        # monitoring_info (g=103) carries the timestamp / local_timestamp pair
        # the parser derives the wearer's UTC offset from.
        info = self._w.define(103, [(253, UINT32, 1), (0, UINT32, 1)])
        naive_local = local_midnight_utc + timedelta(seconds=LOCAL_OFFSET_S)
        self._w.data(
            info, [(UINT32, fit_ts(local_midnight_utc)), (UINT32, fit_ts(naive_local))]
        )

    def snapshot(
        self,
        stamp_utc: str,
        activity_type: int | None = None,
        *,
        steps: int | None = None,
        distance_m: float | None = None,
        active_calories: int | None = None,
        calories: int | None = None,
        moderate_min: int | None = None,
        vigorous_min: int | None = None,
        heart_rate: int | None = None,
        duration_min: int | None = None,
        packed_intensity: int | None = None,
    ) -> MonitorFile:
        """Emit one `monitoring` message. `stamp_utc` is "YYYY-MM-DDTHH:MM" UTC.

        `steps` is written to f3 (`cycles`) as the RAW value, which is what a
        watch does: f3's scale of 2 means the raw number is the step count and
        the scaled `cycles` reading is half of it.

        Pass `packed_intensity` to deliver activity_type through f24
        (`current_activity_type_intensity`) instead of f5, as the intraday
        messages do. fitdecode cannot dispatch a subfield off an expanded
        component, so that shape exposes only `cycles`.
        """
        ts = datetime.strptime(stamp_utc, "%Y-%m-%dT%H:%M").replace(tzinfo=UTC)
        fields: list[tuple[int, int, int]] = []  # (def_num, base_type, value)

        fields.append((253, UINT32, fit_ts(ts)))
        if packed_intensity is not None:
            if activity_type is None:
                raise ValueError("packed f24 needs an activity_type to pack")
            fields.append((24, UINT8, (packed_intensity << 5) | activity_type))
        elif activity_type is not None:
            fields.append((5, ENUM, activity_type))
        if steps is not None:
            fields.append((3, UINT32, steps))
        if distance_m is not None:
            fields.append((2, UINT32, round(distance_m * 100)))
        if calories is not None:
            fields.append((1, UINT16, calories))
        if active_calories is not None:
            fields.append((19, UINT16, active_calories))
        if heart_rate is not None:
            fields.append((27, UINT8, heart_rate))
        if duration_min is not None:
            fields.append((29, UINT16, duration_min))
        if moderate_min is not None:
            fields.append((33, UINT16, moderate_min))
        if vigorous_min is not None:
            fields.append((34, UINT16, vigorous_min))

        local = self._w.define(55, [(num, bt, 1) for num, bt, _ in fields])
        self._w.data(local, [(bt, value) for _, bt, value in fields])
        return self

    def write(self, path: Path) -> Path:
        path.write_bytes(self._w.build())
        return path
