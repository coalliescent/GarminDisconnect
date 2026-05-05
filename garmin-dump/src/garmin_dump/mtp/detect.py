"""`mtp-detect` parser + lock-holder detection.

`mtp-detect` produces a long human-readable dump. We only care about a small slice:
    - whether at least one device is present
    - the vendor / product / friendly name of each device
    - serial number (if libmtp surfaces it)

For lock-holder detection, we shell out to `ps -axo pid,command` once and match each
process command line against known offenders. macOS auto-launches at least four
families of daemons that grab the exclusive USB lock on an MTP/PTP device the moment
it's plugged in (sometimes before, just from being logged in):

    - icdd               — /System/Library/Image Capture/Support/icdd. The classic
                           Image Capture Device Daemon, present since the early 2010s.
    - cameracaptured     — /usr/libexec/cameracaptured. Sonoma/Sequoia/Tahoe-era
                           replacement for mscamerad; lives in ImageCaptureCore.
    - mscamerad / -xpc   — Older name for the same XPC service. Still present on
                           Ventura and earlier.
    - PTPCamera          — Picture Transfer Protocol class daemon.
    - photolibraryd      — Photos library daemon — only an issue if it auto-imports.

Plus the obvious user-facing apps that talk to MTP devices:
    Garmin Express (and its GarminCore/GarminConnect/Web Services daemons),
    Android File Transfer, OpenMTP.

We do not include `usbd` or `usbmuxd` — they don't hold device-class locks on MTP.

The detection is intentionally conservative: we'd rather show a false positive (with
the actual matching pid + command, so the user can verify) than silently fail because
some XPC service is squatting on the lock.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass

from garmin_dump.errors import DeviceBusyError, DeviceNotFoundError
from garmin_dump.mtp.runner import MtpRunner


@dataclass(frozen=True)
class DetectedDevice:
    vendor: str
    product: str
    vendor_id: str | None
    product_id: str | None
    serial: str | None
    friendly_name: str | None


@dataclass(frozen=True)
class LockHolderRule:
    """A pattern we look for, plus a friendly label and a one-line description."""

    label: str         # short human-readable name shown in error/doctor output
    pattern: str       # case-insensitive substring matched against the full command line
    description: str   # explanation of what this process is and why it's a problem


@dataclass(frozen=True)
class LockHolderHit:
    """A concrete match: which rule matched, and the actual processes that were found."""

    rule: LockHolderRule
    pids: tuple[int, ...]
    sample_command: str  # first matching command line, for context


# Each rule is a case-insensitive substring matched against the full command line of
# every running process. Order matters only for display: we list the most descriptive
# label first so it wins when overlapping patterns would match the same pid.
#
# Patterns must be specific enough to avoid false positives. For instance, "icdd" by
# itself would match a lot of unrelated paths; using "Image Capture/Support/icdd" pins
# it to the actual macOS daemon path.
MTP_LOCK_HOLDERS: tuple[LockHolderRule, ...] = (
    LockHolderRule(
        "Garmin Express",
        "/Garmin Express",
        "Garmin's official sync app. Quit it from the menu bar AND via Activity "
        "Monitor — its background helpers can survive a normal cmd-Q.",
    ),
    LockHolderRule(
        "GarminCoreSync",
        "GarminCoreSync",
        "Garmin Express background sync helper. Sometimes survives quitting the app.",
    ),
    LockHolderRule(
        "Garmin Web Services",
        "Garmin Web Services",
        "Garmin Express launch agent. May relaunch on its own; disable in Login Items "
        "if it keeps coming back.",
    ),
    LockHolderRule(
        "icdd (Image Capture Device Daemon)",
        "Image Capture/Support/icdd",
        "macOS auto-launches this when any image-capture device is plugged in. "
        "Killing it via Activity Monitor is safe; launchd respawns it on the next "
        "plug-in event.",
    ),
    LockHolderRule(
        "cameracaptured",
        "/cameracaptured",
        "ImageCaptureCore.framework's XPC service for camera-class USB devices "
        "(MTP cameras and watches), Sonoma+ name. Always running on modern macOS — "
        "Activity Monitor → quit, then unplug and replug the watch.",
    ),
    LockHolderRule(
        "mscamerad / mscamerad-xpc",
        "mscamerad",
        "Older (Ventura and earlier) name for cameracaptured. Same role; same fix.",
    ),
    LockHolderRule(
        "PTPCamera",
        "/PTPCamera",
        "macOS Picture Transfer Protocol class daemon. Quit via Activity Monitor.",
    ),
    LockHolderRule(
        "Android File Transfer",
        "Android File Transfer",
        "Quit the app from the menu bar.",
    ),
    LockHolderRule(
        "OpenMTP",
        "OpenMTP",
        "Quit the app from the menu bar.",
    ),
    LockHolderRule(
        "Photos / photolibraryd",
        "/photolibraryd",
        "Photos library daemon — only an issue if it auto-imports from your watch. "
        "Disable Photos auto-import in Photos > Settings > General.",
    ),
)


def _list_processes() -> list[tuple[int, str]]:
    """Return [(pid, command-line)] for every running process. Single subprocess call.

    Uses `ps` instead of `pgrep` because macOS pgrep doesn't support GNU's `-a` flag
    (which would print command lines alongside pids). With ps we get the full command
    line for free and we only spawn one subprocess for the whole scan.
    """
    ps_path = shutil.which("ps")
    if ps_path is None:
        return []
    try:
        proc = subprocess.run(
            [ps_path, "-axo", "pid=,command="],
            capture_output=True,
            text=True,
            timeout=5.0,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return []
    if proc.returncode != 0:
        return []
    out: list[tuple[int, str]] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        head, _, rest = line.partition(" ")
        try:
            out.append((int(head), rest.strip()))
        except ValueError:
            continue
    return out


def find_lock_holders() -> list[LockHolderHit]:
    """Scan running processes and return all matching lock holder hits."""
    procs = _list_processes()
    if not procs:
        return []
    hits: list[LockHolderHit] = []
    seen_pids: set[int] = set()
    for rule in MTP_LOCK_HOLDERS:
        needle = rule.pattern.lower()
        matched: list[tuple[int, str]] = []
        for pid, cmd in procs:
            if pid in seen_pids:
                continue
            if needle in cmd.lower():
                matched.append((pid, cmd))
        if matched:
            for pid, _ in matched:
                seen_pids.add(pid)
            hits.append(
                LockHolderHit(
                    rule=rule,
                    pids=tuple(p for p, _ in matched),
                    sample_command=matched[0][1],
                )
            )
    return hits


def assert_no_lock_holders() -> None:
    """Raise DeviceBusyError if any known MTP lock holder is running."""
    hits = find_lock_holders()
    if hits:
        raise DeviceBusyError([_format_hit(h) for h in hits])


def _format_hit(hit: LockHolderHit) -> str:
    pids = ",".join(str(p) for p in hit.pids)
    return (
        f"{hit.rule.label} (pid {pids}): {hit.rule.description}\n"
        f"    matched command: {hit.sample_command}"
    )


# ---- mtp-detect output parser ----------------------------------------------------------

# Each device block in mtp-detect output starts with a header like one of:
#   Device 0 (VID=091e and PID=4c45) is a Garmin Instinct 3.
#   Device 0 (VID=091e and PID=51e9) is UNKNOWN in libmtp v1.1.23.
# The "is a/an X" form only appears for devices in libmtp's hardcoded VID/PID
# database. New Garmin watches (like the Instinct 3, PID 0x51e9) are not in the
# bundled database for libmtp 1.1.23 — but MTP itself works fine because libmtp
# probes the USB descriptors and finds the MTP interface anyway.
_DEVICE_HEADER_RE = re.compile(
    r"Device\s+(\d+)\s*\(VID=([0-9a-fA-F]+)\s+and\s+PID=([0-9a-fA-F]+)\)\s+is\s+(.+?)$",
    re.IGNORECASE | re.MULTILINE,
)

# Garmin's USB vendor ID. Source: USB-IF, also visible in every Garmin watch's USB
# descriptor. We treat any device with this VID as a Garmin device, regardless of
# whether libmtp's database knows the specific PID.
GARMIN_USB_VENDOR_ID = "091e"

# The fields we care about live in two places in the mtp-detect output:
#   - the "Raw device info:" section, which has Vendor: / Product: lines that are
#     often "(null)" for Garmin devices
#   - the "Device info:" section (after libmtp opens the device), which has the
#     authoritative Manufacturer:, Model:, Serial number: lines
# We try the Manufacturer/Model fields first and fall back to Vendor/Product.
_MANUFACTURER_RE = re.compile(r"^\s*Manufacturer:\s*(.+?)\s*$", re.MULTILINE)
_MODEL_RE = re.compile(r"^\s*Model:\s*(.+?)\s*$", re.MULTILINE)
_VENDOR_RE = re.compile(r"^\s*Vendor:\s*(.+?)\s*$", re.MULTILINE)
_PRODUCT_RE = re.compile(r"^\s*Product:\s*(.+?)\s*$", re.MULTILINE)
_SERIAL_RE = re.compile(r"^\s*Serial(?:\s*[Nn]umber)?:\s*(.+?)\s*$", re.MULTILINE)
_FRIENDLY_RE = re.compile(r"^\s*Friendly\s*name?:\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)


def parse_mtp_detect(stdout: str) -> list[DetectedDevice]:
    """Parse `mtp-detect` output into a list of DetectedDevice records.

    Tolerant of unknown fields and out-of-order sections. The "Device N (VID=… and
    PID=…)" header line is the only required marker for a device's presence; the
    descriptive tail (`is a Foo Bar.` or `is UNKNOWN in libmtp v1.1.23.`) is parsed
    permissively because libmtp's wording varies between known and unknown PIDs.
    """
    devices: list[DetectedDevice] = []
    headers = list(_DEVICE_HEADER_RE.finditer(stdout))
    if not headers:
        return devices
    for i, m in enumerate(headers):
        start = m.end()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(stdout)
        block = stdout[start:end]

        # Prefer Manufacturer/Model (from "Device info:") over raw Vendor/Product
        # (from "Raw device info:"), because Garmin sets the latter to "(null)".
        manufacturer = _clean_or_none(_first_match(_MANUFACTURER_RE, block))
        model = _clean_or_none(_first_match(_MODEL_RE, block))
        raw_vendor = _clean_or_none(_first_match(_VENDOR_RE, block))
        raw_product = _clean_or_none(_first_match(_PRODUCT_RE, block))

        # If both Manufacturer and Model exist, use them. Otherwise fall back to
        # whatever raw fields we found, and finally to the descriptive tail of the
        # header line itself ("Garmin Instinct 3" or "UNKNOWN in libmtp v1.1.23").
        # The legacy header form is "is a Foo Bar." / "is an Apple Bar." — strip
        # the article so the friendly name doesn't end up as "a Garmin Edge 1040".
        header_tail = m.group(4).rstrip(".").strip()
        if header_tail.lower().startswith("a "):
            header_tail = header_tail[2:]
        elif header_tail.lower().startswith("an "):
            header_tail = header_tail[3:]
        vendor = manufacturer or raw_vendor or (header_tail.split()[0] if header_tail else "")
        product = model or raw_product or header_tail

        serial = _clean_or_none(_first_match(_SERIAL_RE, block))
        friendly = _clean_or_none(_first_match(_FRIENDLY_RE, block))
        devices.append(
            DetectedDevice(
                vendor=vendor or "",
                product=product or "",
                vendor_id=m.group(2).lower(),
                product_id=m.group(3).lower(),
                serial=serial,
                friendly_name=friendly,
            )
        )
    return devices


def _first_match(pattern: re.Pattern[str], text: str) -> str | None:
    m = pattern.search(text)
    return m.group(1).strip() if m else None


def _clean_or_none(s: str | None) -> str | None:
    """Return s, treating libmtp's '(null)' placeholder as None."""
    if s is None:
        return None
    s = s.strip()
    if not s or s.lower() == "(null)":
        return None
    return s


# ---- public façade ---------------------------------------------------------------------


def detect_devices(runner: MtpRunner) -> list[DetectedDevice]:
    """Run mtp-detect and parse its output. Empty list if no device is present.

    Reads the combined stdout+stderr stream because mtp-detect mixes them: the
    `Device N (VID=… and PID=…)` header line in particular is sometimes printed to
    stderr depending on libmtp version, and was missed by an earlier version of
    this parser that only looked at stdout.
    """
    result = runner.run("mtp-detect", timeout=20.0)
    # mtp-detect exits non-zero when no device is present, but the output still contains
    # the libmtp banner — that's not an error for us, just "no devices".
    return parse_mtp_detect(result.combined)


def detect_garmin(runner: MtpRunner) -> DetectedDevice:
    """Find the first Garmin device. Identifies by USB VID 0x091e first; falls back
    to a substring match on the vendor/product strings if the VID isn't present
    (which would be a libmtp parse failure on our side, not a real device problem).
    """
    for d in detect_devices(runner):
        if d.vendor_id == GARMIN_USB_VENDOR_ID:
            return d
        if "garmin" in d.vendor.lower() or "garmin" in (d.product or "").lower():
            return d
    raise DeviceNotFoundError(
        "no Garmin MTP device detected. Verify with `mtp-detect` directly. "
        "If `mtp-detect` finds the device but garmin-dump doesn't, this is a "
        "parser bug — please report the full mtp-detect output."
    )
