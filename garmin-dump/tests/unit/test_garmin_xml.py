"""Tests for the GarminDevice.xml parser."""

from __future__ import annotations

from pathlib import Path

import pytest

from garmin_dump.device.garmin_xml import (
    DeviceInfo,
    parse_garmin_device_xml,
    parse_garmin_device_xml_path,
)
from garmin_dump.errors import GarminXmlError

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def test_parses_known_fixture() -> None:
    info = parse_garmin_device_xml_path(FIXTURES / "garmin_device_sample.xml")
    assert info.serial == "3835327190"
    assert info.unit_id == "3835327190"
    assert info.model == "Instinct 3 Solar"
    assert info.part_number == "006-B5023-00"
    assert info.software_version == "520"
    assert info.archive_serial == "3835327190"


def test_falls_back_to_unit_id_when_no_serial() -> None:
    xml = b"""<?xml version="1.0"?>
    <Device xmlns="http://www.garmin.com/xmlschemas/GarminDevice/v2">
        <Id>fallback-id-9999</Id>
        <Model><Description>Test</Description></Model>
    </Device>"""
    info = parse_garmin_device_xml(xml)
    assert info.serial is None
    assert info.unit_id == "fallback-id-9999"
    assert info.archive_serial == "fallback-id-9999"


def test_raises_when_no_identifier() -> None:
    xml = b"""<?xml version="1.0"?>
    <Device xmlns="http://www.garmin.com/xmlschemas/GarminDevice/v2">
        <Model><Description>Mystery</Description></Model>
    </Device>"""
    info = parse_garmin_device_xml(xml)
    with pytest.raises(GarminXmlError):
        _ = info.archive_serial


def test_raises_on_malformed_xml() -> None:
    with pytest.raises(GarminXmlError):
        parse_garmin_device_xml(b"<not-valid")
