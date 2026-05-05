"""Tests for the `mtp-detect` output parser.

The fixture text is real output captured from a Garmin Instinct 3 - 45mm against
libmtp 1.1.23 — NOT a hand-crafted approximation. The parser must survive the two
quirks that real libmtp produces:

    - The header tail says "is UNKNOWN in libmtp v1.1.23." for any device whose
      VID/PID isn't in libmtp's hardcoded database (which includes brand-new Garmin
      watches in 2026).
    - The "Raw device info:" section reports Vendor/Product as "(null)". The
      authoritative names live further down in the "Device info:" section as
      Manufacturer:/Model:.
"""

from __future__ import annotations

from pathlib import Path

from garmin_dump.mtp.detect import GARMIN_USB_VENDOR_ID, parse_mtp_detect

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def test_parses_real_instinct3_fixture() -> None:
    devices = parse_mtp_detect((FIXTURES / "mtp_detect_sample.txt").read_text())
    assert len(devices) == 1
    d = devices[0]
    assert d.vendor_id == GARMIN_USB_VENDOR_ID  # "091e"
    assert d.product_id == "51e9"
    # Manufacturer/Model should be picked up from "Device info:" not the (null)s
    assert d.vendor == "Garmin"
    assert d.product == "Instinct 3 - 45mm"
    assert d.serial == "0000d1281fa5"


def test_handles_unknown_in_libmtp_header() -> None:
    """The header line for unknown PIDs ends in 'UNKNOWN in libmtp vX.Y.Z.'
    instead of 'is a Foo Bar.'. Make sure we still parse it."""
    text = (
        "Device 0 (VID=091e and PID=ffff) is UNKNOWN in libmtp v1.1.23.\n"
        "libmtp version: 1.1.23\n"
        "Device info:\n"
        "   Manufacturer: Garmin\n"
        "   Model: Future Watch\n"
        "   Serial number: ABC123\n"
    )
    devices = parse_mtp_detect(text)
    assert len(devices) == 1
    assert devices[0].vendor_id == "091e"
    assert devices[0].product == "Future Watch"
    assert devices[0].vendor == "Garmin"


def test_handles_known_device_header() -> None:
    """The legacy 'is a Foo Bar.' wording must still parse for older Garmin models
    that ARE in libmtp's database."""
    text = (
        "Device 0 (VID=091e and PID=4c45) is a Garmin Edge 1040.\n"
        "libmtp version: 1.1.23\n"
        "   Manufacturer: Garmin\n"
        "   Model: Edge 1040\n"
        "   Serial number: 12345\n"
    )
    devices = parse_mtp_detect(text)
    assert len(devices) == 1
    assert devices[0].vendor == "Garmin"
    assert devices[0].product == "Edge 1040"


def test_falls_back_to_header_tail_when_no_device_info_section() -> None:
    """If libmtp can't open the device, we won't see Manufacturer/Model — but we
    should still surface the header tail so the user gets *something*."""
    text = "Device 0 (VID=abcd and PID=1234) is a Mystery Device.\n"
    devices = parse_mtp_detect(text)
    assert len(devices) == 1
    assert devices[0].vendor_id == "abcd"
    assert devices[0].product == "Mystery Device"


def test_treats_null_vendor_product_as_missing() -> None:
    """Garmin watches print '(null)' for the raw Vendor:/Product:. Don't report
    that as the friendly name."""
    text = (
        "Device 0 (VID=091e and PID=51e9) is UNKNOWN in libmtp v1.1.23.\n"
        "         Vendor: (null)\n"
        "         Product: (null)\n"
        "   Manufacturer: Garmin\n"
        "   Model: Instinct 3\n"
    )
    devices = parse_mtp_detect(text)
    assert devices[0].vendor == "Garmin"
    assert devices[0].product == "Instinct 3"


def test_returns_empty_when_no_devices() -> None:
    devices = parse_mtp_detect("libmtp version: 1.1.23\n\nNo devices found.\nOK.\n")
    assert devices == []
