"""Tests for detect_garmin_with_retry (item #237).

Right after a watch is plugged in, `mtp-detect` can report "no device" for 10+
seconds while the kernel/USB stack finishes enumerating it. A sync that gives up
on the first miss fails spuriously. detect_garmin_with_retry() retries
DeviceNotFoundError over a time budget instead of propagating it immediately.
"""

from __future__ import annotations

import pytest

from garmin_dump.errors import DeviceBusyError, DeviceNotFoundError
from garmin_dump.mtp.detect import detect_garmin_with_retry
from garmin_dump.mtp.runner import MtpResult

NO_DEVICE_OUTPUT = "libmtp version: 1.1.23\n\nNo devices found.\nOK.\n"
GARMIN_OUTPUT = (
    "Device 0 (VID=091e and PID=51e9) is UNKNOWN in libmtp v1.1.23.\n"
    "libmtp version: 1.1.23\n"
    "Device info:\n"
    "   Manufacturer: Garmin\n"
    "   Model: Instinct 3 - 45mm\n"
    "   Serial number: 0000d1281fa5\n"
)


class _ScriptedRunner:
    """Fake MtpRunner that returns a scripted sequence of mtp-detect outputs."""

    def __init__(self, outputs: list[str]) -> None:
        self._outputs = list(outputs)
        self.calls = 0

    def run(self, tool: str, *args: str, timeout: float = 60.0, check: bool = False) -> MtpResult:
        assert tool == "mtp-detect"
        self.calls += 1
        idx = min(self.calls - 1, len(self._outputs) - 1)
        return MtpResult(args=[tool, *args], returncode=1, stdout=self._outputs[idx], stderr="")


def test_succeeds_immediately_without_sleeping() -> None:
    runner = _ScriptedRunner([GARMIN_OUTPUT])
    sleeps: list[float] = []
    clock = _FakeClock()

    device = detect_garmin_with_retry(
        runner, sleep=sleeps.append, clock=clock, timeout_s=30.0, interval_s=3.0
    )

    assert device.vendor == "Garmin"
    assert runner.calls == 1
    assert sleeps == []


def test_retries_until_device_appears() -> None:
    # Device is missing for the first two attempts, present on the third.
    runner = _ScriptedRunner([NO_DEVICE_OUTPUT, NO_DEVICE_OUTPUT, GARMIN_OUTPUT])
    sleeps: list[float] = []
    clock = _FakeClock()

    device = detect_garmin_with_retry(
        runner, sleep=sleeps.append, clock=clock, timeout_s=30.0, interval_s=3.0
    )

    assert device.vendor == "Garmin"
    assert runner.calls == 3
    assert sleeps == [3.0, 3.0]


def test_gives_up_after_timeout() -> None:
    runner = _ScriptedRunner([NO_DEVICE_OUTPUT])
    clock = _FakeClock()

    def fake_sleep(seconds: float) -> None:
        clock.advance(seconds)

    with pytest.raises(DeviceNotFoundError):
        detect_garmin_with_retry(
            runner, sleep=fake_sleep, clock=clock, timeout_s=10.0, interval_s=3.0
        )

    # 10s budget / 3s interval -> attempts at t=0,3,6,9,10 (5 attempts); the
    # last one's remaining-time check hits zero and raises instead of sleeping.
    assert runner.calls == 5


def test_does_not_retry_non_not_found_errors() -> None:
    class _BusyRunner:
        def run(self, tool: str, *args: str, timeout: float = 60.0, check: bool = False) -> MtpResult:
            raise DeviceBusyError(["Garmin Express (pid 123): ..."])

    calls: list[float] = []
    with pytest.raises(DeviceBusyError):
        detect_garmin_with_retry(_BusyRunner(), sleep=calls.append, clock=_FakeClock())
    assert calls == []


class _FakeClock:
    """Monotonic-ish fake clock: starts at 0, advances only via advance()/sleep."""

    def __init__(self) -> None:
        self._t = 0.0

    def advance(self, seconds: float) -> None:
        self._t += seconds

    def __call__(self) -> float:
        return self._t
