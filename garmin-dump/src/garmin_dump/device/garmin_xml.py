"""Parse `GarminDevice.xml` from a Garmin watch.

`GarminDevice.xml` lives at `/GARMIN/GarminDevice.xml` on every Garmin device. It uses
a long-form XML namespace (`http://www.garmin.com/xmlschemas/GarminDevice/v2`) which we
strip during parsing for ergonomics.

Fields we care about:
    - Device/Id          → unit ID (numeric)
    - Device/Model/PartNumber
    - Device/Model/Description
    - Device/Model/SoftwareVersion
    - Device/Model/Serial → serial (preferred for archive namespacing)

If `Serial` is absent we fall back to `Id`. Either is stable across reboots.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

from garmin_dump.errors import GarminXmlError


@dataclass(frozen=True)
class DeviceInfo:
    """Identification fields extracted from GarminDevice.xml."""

    unit_id: str | None
    serial: str | None
    part_number: str | None
    model: str | None
    software_version: str | None

    @property
    def archive_serial(self) -> str:
        """The string used to namespace the on-disk archive directory.

        Prefers `serial` (the consumer-facing serial number printed on the box) over
        `unit_id` (an internal identifier). Either is stable.
        """
        s = self.serial or self.unit_id
        if not s:
            raise GarminXmlError(
                "GarminDevice.xml has neither <Serial> nor <Id> — cannot determine "
                "a stable archive namespace for this device."
            )
        return s.strip()


def parse_garmin_device_xml(xml_bytes: bytes) -> DeviceInfo:
    """Parse a GarminDevice.xml byte string into a DeviceInfo.

    Raises GarminXmlError on malformed input or missing required fields.
    """
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as e:
        raise GarminXmlError(f"GarminDevice.xml is not well-formed: {e}") from e

    # The root tag is namespaced; strip the namespace from every tag for ergonomic
    # XPath-style lookups below.
    for elem in root.iter():
        if "}" in elem.tag:
            elem.tag = elem.tag.split("}", 1)[1]

    # Find the first <Device> child (there's normally exactly one).
    device = root if root.tag == "Device" else root.find("Device")
    if device is None:
        # Some firmwares use <GarminDevice> as the root with <Device> nested.
        device = root.find(".//Device") or root

    unit_id = _text(device.find("Id"))
    model_node = device.find("Model")
    part_number = _text(model_node.find("PartNumber")) if model_node is not None else None
    model = _text(model_node.find("Description")) if model_node is not None else None
    software_version = (
        _text(model_node.find("SoftwareVersion")) if model_node is not None else None
    )
    # Serial may live under Model or directly under Device, depending on firmware.
    serial = None
    if model_node is not None:
        serial = _text(model_node.find("Serial"))
    if not serial:
        serial = _text(device.find("Serial"))
    if not serial:
        # Last resort: <DeviceSerial>
        serial = _text(device.find(".//DeviceSerial"))

    return DeviceInfo(
        unit_id=unit_id,
        serial=serial,
        part_number=part_number,
        model=model,
        software_version=software_version,
    )


def _text(node: ET.Element | None) -> str | None:
    if node is None:
        return None
    if node.text is None:
        return None
    s = node.text.strip()
    return s or None


def parse_garmin_device_xml_path(path: Path) -> DeviceInfo:
    return parse_garmin_device_xml(path.read_bytes())


def device_info_to_json(info: DeviceInfo) -> str:
    return json.dumps(asdict(info), indent=2, sort_keys=True)
