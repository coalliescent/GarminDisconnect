#!/usr/bin/env python3
"""Generate the synthetic FIT fixtures used by the parser tests.

Created 2026-08-31.

The sleep and monitoring parsers need real-shaped FIT input to test against,
but the files that shape came from are the wearer's own health telemetry:
they carry a device serial and a night's worth of biometrics, and the repo's
root `.gitignore` excludes `*.fit` / `*.FIT` precisely so they never get
committed. That left the two fixtures un-committable, and 13 tests red on
every fresh clone.

So we synthesize them instead. This script writes byte-exact FIT files
containing only the message types the parsers decode, populated with
plausible-but-invented values. No personal data, deterministic output, and
the fixtures are committed via a `!` negation in the root `.gitignore`.

Regenerate with:

    python garmin-dump/tests/fixtures/build_fit_fixtures.py

What each fixture contains:

  sleep_F5I94001.fit   file_id(type=49 sleep)
                       273 sleep_data_info    x1   (f253 utc, f2 local)
                       275 sleep_level        x12  (f253 utc, f0 stage enum)
                       346 sleep_assessment   x1   (17 fields, f3 = score)
                       382 sleep_restless_moments x1 (f253, f0 byte[200])

  monitor_M47N0648.FIT file_id(type=32 monitoring_b)
                       227 stress_level       x120 (f1 utc, f0 stress,
                                                    f2 forensic, f3 sparse hrv)
                       297 respiration_rate   x120 (f253 utc, f0 sint16 x100)

The FIT binary layout implemented here is the public spec: a 14-byte header
(with its own CRC), a stream of definition/data records, and a trailing
CRC-16 over everything before it.
"""

from __future__ import annotations

import struct
from datetime import UTC, datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent

# ---- FIT primitives --------------------------------------------------------

# Base type numbers from the FIT SDK. The high bit marks an endian-sensitive
# (multi-byte) type; the low nibble indexes the type table.
ENUM = 0x00
SINT8 = 0x01
UINT8 = 0x02
SINT16 = 0x83
UINT16 = 0x84
UINT32 = 0x86
BYTE = 0x0D

_SIZES = {ENUM: 1, SINT8: 1, UINT8: 1, SINT16: 2, UINT16: 2, UINT32: 4, BYTE: 1}
_PACK = {ENUM: "B", SINT8: "b", UINT8: "B", SINT16: "h", UINT16: "H", UINT32: "I"}

_CRC_TABLE = (
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
)


def fit_crc(data: bytes, crc: int = 0) -> int:
    """The FIT spec's nibble-wise CRC-16."""
    for byte in data:
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[byte & 0xF]
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[(byte >> 4) & 0xF]
    return crc


class FitWriter:
    """Accumulates definition + data records, then emits a complete FIT file.

    Local message types are assigned on first use of a global mesg num. FIT
    allows 16 of them (0-15), which is far more than any fixture needs.
    """

    def __init__(self) -> None:
        self._records = bytearray()
        self._local: dict[int, int] = {}
        self._next_local = 0

    def define(self, global_num: int, fields: list[tuple[int, int, int]]) -> int:
        """Emit a definition message. `fields` is [(def_num, base_type, count)].

        Returns the local message type to pass to `data()`.
        """
        if self._next_local > 15:
            raise ValueError("FIT allows at most 16 local message types")
        local = self._next_local
        self._next_local += 1
        self._local[global_num] = local

        rec = bytearray()
        rec.append(0x40 | local)          # definition message, no developer data
        rec.append(0)                     # reserved
        rec.append(0)                     # architecture: 0 = little endian
        rec += struct.pack("<H", global_num)
        rec.append(len(fields))
        for def_num, base_type, count in fields:
            rec.append(def_num)
            rec.append(_SIZES[base_type] * count)
            rec.append(base_type)
        self._records += rec
        return local

    def data(self, local: int, values: list[tuple[int, object]]) -> None:
        """Emit a data message. `values` is [(base_type, value)] in definition
        order; a bytes value is written verbatim (for byte arrays)."""
        rec = bytearray()
        rec.append(local)                 # data message, normal header
        for base_type, value in values:
            if isinstance(value, bytes):
                rec += value
            else:
                rec += struct.pack("<" + _PACK[base_type], value)
        self._records += rec

    def build(self) -> bytes:
        header = bytearray()
        header.append(14)                 # header size
        header.append(0x20)               # protocol version 2.0
        header += struct.pack("<H", 2140)  # profile version
        header += struct.pack("<I", len(self._records))
        header += b".FIT"
        header += struct.pack("<H", fit_crc(bytes(header)))

        body = bytes(header) + bytes(self._records)
        return body + struct.pack("<H", fit_crc(body))


# ---- FIT timestamps --------------------------------------------------------

FIT_EPOCH = datetime(1989, 12, 31, tzinfo=UTC)


def fit_ts(dt: datetime) -> int:
    return int((dt - FIT_EPOCH).total_seconds())


# A fixed night/day so the fixtures are byte-identical on every regeneration.
NIGHT_START = datetime(2026, 3, 14, 22, 30, tzinfo=UTC)
DAY_START = datetime(2026, 3, 15, 0, 0, tzinfo=UTC)
LOCAL_OFFSET_S = -7 * 3600  # America/Los_Angeles in March, for the local-ts field


def _file_id(w: FitWriter, file_type: int, serial: int, created: datetime) -> None:
    """Every FIT file opens with file_id; the parsers require it."""
    local = w.define(
        0,
        [(0, ENUM, 1), (1, UINT16, 1), (2, UINT16, 1), (3, UINT32, 1), (4, UINT32, 1)],
    )
    w.data(
        local,
        [
            (ENUM, file_type),
            (UINT16, 1),          # manufacturer: garmin
            (UINT16, 4443),       # product: an Instinct-family id
            (UINT32, serial),
            (UINT32, fit_ts(created)),
        ],
    )


# ---- sleep fixture ---------------------------------------------------------

# 12 stage transitions through a night, using the enum from Garmin's FIT Java
# SDK SleepLevel.java: 0=unmeasurable 1=awake 2=light 3=deep 4=rem.
_SLEEP_STAGES = [1, 2, 3, 2, 4, 2, 3, 2, 4, 2, 1, 0]

# Minutes into the night at which each transition above happens. Irregular on
# purpose — a uniform grid would hide an off-by-one in the duration walk.
_SLEEP_OFFSETS_MIN = [0, 7, 34, 76, 95, 128, 160, 205, 232, 268, 401, 415]


def build_sleep() -> bytes:
    w = FitWriter()
    _file_id(w, 49, 3509067685 % 100000, NIGHT_START + timedelta(hours=8))

    # 273 sleep_data_info — the session anchor. f253 is the UTC FIT timestamp,
    # f2 is the same instant written as if it were local wall-clock; the
    # parser subtracts them to recover the wearer's UTC offset.
    info = w.define(273, [(253, UINT32, 1), (2, UINT32, 1), (0, UINT8, 1)])
    w.data(
        info,
        [
            (UINT32, fit_ts(NIGHT_START)),
            (UINT32, fit_ts(NIGHT_START) + LOCAL_OFFSET_S),
            (UINT8, 1),
        ],
    )

    # 275 sleep_level — the stage timeline the hypnogram is built from.
    level = w.define(275, [(253, UINT32, 1), (0, ENUM, 1)])
    for stage, minutes in zip(_SLEEP_STAGES, _SLEEP_OFFSETS_MIN, strict=True):
        w.data(
            level,
            [(UINT32, fit_ts(NIGHT_START + timedelta(minutes=minutes))), (ENUM, stage)],
        )

    # 346 sleep_assessment — 17 fields, only some of which the community has
    # named. f3 is the parser's best-candidate sleep score, so it must land in
    # 0..100. f15 is uint16 (scale 100). f12/f13/f16 are still unnamed.
    assessment_fields = [
        (0, UINT8, 24), (1, UINT8, 91), (2, UINT8, 88), (3, UINT8, 82),
        (4, UINT8, 79), (5, UINT8, 73), (6, UINT8, 82), (7, UINT8, 68),
        (8, UINT8, 77), (9, UINT8, 64), (10, UINT8, 85), (11, UINT8, 3),
        (12, UINT8, 2), (13, UINT8, 1), (14, UINT8, 90), (16, UINT8, 0),
    ]
    assess = w.define(
        346,
        [(dn, bt, 1) for dn, bt, _ in assessment_fields] + [(15, UINT16, 1)],
    )
    w.data(
        assess,
        [(bt, v) for _, bt, v in assessment_fields] + [(UINT16, 1850)],
    )

    # 382 sleep_restless_moments — a 200-byte per-minute movement waveform.
    # Semantics unknown; the parser stashes it verbatim in raw_json, so all
    # the fixture has to do is be a well-formed 200-byte array with no 0xFF
    # (0xFF is the byte type's invalid sentinel).
    restless = w.define(382, [(253, UINT32, 1), (0, BYTE, 200)])
    waveform = bytes((i * 7 + 3) % 250 for i in range(200))
    w.data(restless, [(UINT32, fit_ts(NIGHT_START)), (BYTE, waveform)])

    return w.build()


# ---- monitor fixture -------------------------------------------------------

_N_SAMPLES = 120  # 2-minute cadence => 4 hours of the morning


def build_monitor() -> bytes:
    w = FitWriter()
    _file_id(w, 32, 3509067685 % 100000, DAY_START + timedelta(hours=6))

    # 227 stress_level. Note f1 (not f253) carries the timestamp on this
    # message — the parser depends on that. f2 and f4 are unsolved companion
    # fields; f3 is a sparse value that looks like HRV RMSSD in ms.
    stress = w.define(
        227,
        [(1, UINT32, 1), (0, SINT16, 1), (2, SINT8, 1), (3, SINT8, 1)],
    )
    for i in range(_N_SAMPLES):
        ts = DAY_START + timedelta(minutes=2 * i)
        # A slow wave through 18..72, which is a believable overnight-to-
        # morning stress curve and stays inside the parser's 0..100 gate.
        level = 45 + int(27 * ((i % 40) - 20) / 20)
        f2 = ((i * 13) % 199) - 97          # -97..+101, dense, sint8-safe
        f3 = 18 + (i % 65) if i % 4 == 0 else 0   # in 10..150 only 1 in 4
        w.data(stress, [(UINT32, fit_ts(ts)), (SINT16, level), (SINT8, f2), (SINT8, f3)])

    # 297 respiration_rate. f0 is sint16 breaths/min x100; the parser divides
    # by 100 and rejects anything <= 0 (Garmin's no-signal sentinel is -200).
    resp = w.define(297, [(253, UINT32, 1), (0, SINT16, 1)])
    for i in range(_N_SAMPLES):
        ts = DAY_START + timedelta(minutes=2 * i)
        brpm_x100 = 1420 + ((i * 31) % 380)  # 14.20 .. 17.99 br/min
        w.data(resp, [(UINT32, fit_ts(ts)), (SINT16, brpm_x100)])

    return w.build()


def main() -> None:
    for name, data in (
        ("sleep_F5I94001.fit", build_sleep()),
        ("monitor_M47N0648.FIT", build_monitor()),
    ):
        path = HERE / name
        path.write_bytes(data)
        print(f"wrote {path.relative_to(HERE.parent.parent)} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
