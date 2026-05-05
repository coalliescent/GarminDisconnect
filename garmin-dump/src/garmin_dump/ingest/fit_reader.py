"""Thin wrapper around `fitdecode` that yields normalized data messages.

We don't try to abstract away fitdecode's frame types — calls into the per-category
modules (`activity.py`, `monitoring.py`, …) need raw access to a `FitDataMessage` so
they can call `.get_value()` and `.get_field()` directly.

What this module does provide:

    - `read_messages(path)` — yields `(name, message)` tuples for every FitDataMessage,
      skipping headers/CRC frames.
    - `peek_file_type(path)` — reads the `file_id` message and returns its `type` field
      (e.g. "activity", "monitoring_a", "sleep", "metrics", or None for unknown).
      The directory the file came from is just a hint — the FIT header is authoritative.
    - `MessageBuckets` — convenience that buckets a whole file's messages by name.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import fitdecode


def read_messages(path: Path) -> Iterator[fitdecode.FitDataMessage]:
    """Yield every FitDataMessage in `path`, in order."""
    with fitdecode.FitReader(str(path)) as fit:
        for frame in fit:
            if isinstance(frame, fitdecode.FitDataMessage):
                yield frame


def msg_num(msg: fitdecode.FitDataMessage) -> int:
    """Return the integer global mesg num for a data message.

    Works equally well for fitdecode-recognized messages (where it reads
    `msg.global_mesg_num`) and for `unknown_NNN` messages (where the same
    attribute is set from the wire definition). Returns -1 only if neither
    path yields an integer, which would indicate a malformed frame.
    """
    n = getattr(msg, "global_mesg_num", None)
    if isinstance(n, int):
        return n
    name = msg.name
    if name.startswith("unknown_"):
        try:
            return int(name.removeprefix("unknown_"))
        except ValueError:
            return -1
    return -1


def raw_field_values(msg: fitdecode.FitDataMessage) -> dict[int, Any]:
    """Return `{def_num: raw_value}` for every field on a data message.

    We deliberately use `fd.raw_value` (the unscaled wire value) rather than
    `fd.value` (which fitdecode 0.11+ may have decoded into a string for
    enums or a `datetime` for FIT-epoch timestamps when it has a profile
    entry for the field). Handlers stay version-agnostic by working with the
    raw integer / bytes — they apply their own scaling and look up enum
    labels from canonical SDK tables.
    """
    return {fd.def_num: fd.raw_value for fd in msg.fields}


def iter_messages_for_num(
    path: Path, nums: Iterable[int]
) -> Iterator[fitdecode.FitDataMessage]:
    """Stream only messages whose global mesg num is in `nums`.

    The integer-keyed equivalent of `iter_messages_for(path, names)`. Used by
    monitoring ingest to consume `unknown_NNN` streams without bucketing the
    whole file in memory.
    """
    wanted = set(nums)
    for msg in read_messages(path):
        if msg_num(msg) in wanted:
            yield msg


# Integer file_id.type values that fitdecode 0.11 doesn't decode to enum
# strings. Sourced from Garmin's FIT SDK plus the HarryOnline community sheet
# (see memory/reference_fit_decoding.md). Anything not in this map and not
# already decoded by fitdecode falls through and the dispatcher uses the
# directory category hint.
_FILE_TYPE_INT_TO_NAME: dict[int, str] = {
    4: "activity",       # already decoded by fitdecode but listed for completeness
    32: "monitoring_b",  # already decoded by fitdecode
    44: "metrics",       # community
    49: "sleep",         # community
    68: "hrv_status",    # community — newer firmware, lives in Monitor/ folder
}


def peek_file_type(path: Path) -> str | None:
    """Return a canonical handler name for the file's `file_id.type` field.

    fitdecode 0.11 decodes some file types into strings (e.g. "activity",
    "monitoring_b") but returns the raw integer for newer values that aren't
    in its profile (e.g. 49=sleep, 44=metrics, 68=hrv_status). We normalize
    integer values via `_FILE_TYPE_INT_TO_NAME` so the dispatcher's
    string-based switch always sees a stable name.
    """
    with fitdecode.FitReader(str(path)) as fit:
        for frame in fit:
            if not (
                isinstance(frame, fitdecode.FitDataMessage) and frame.name == "file_id"
            ):
                continue
            try:
                v = frame.get_value("type", fallback=None)
            except KeyError:
                return None
            if v is None:
                return None
            if isinstance(v, str):
                return v
            if isinstance(v, int):
                return _FILE_TYPE_INT_TO_NAME.get(v, str(v))
            return str(v)
    return None


def safe_get(msg: fitdecode.FitDataMessage, name: str) -> Any:
    """Return `msg.get_value(name)` or None if the field is missing/unset."""
    try:
        return msg.get_value(name, fallback=None)
    except KeyError:
        return None


def field_units(msg: fitdecode.FitDataMessage, name: str) -> str | None:
    """Return the FIT-declared units string for a field, or None."""
    try:
        fld = msg.get_field(name)
    except KeyError:
        return None
    units = getattr(fld, "units", None)
    return str(units) if units else None


def message_to_dict(msg: fitdecode.FitDataMessage) -> dict[str, Any]:
    """Snapshot a message's fields into a plain dict (for raw_*_json columns).

    Field values that are bytes / datetimes / enums are coerced to strings via the
    json `default=str` path at write time, so we don't need to coerce here.
    """
    out: dict[str, Any] = {}
    for fld in msg.fields:
        out[fld.name] = fld.value
    return out


@dataclass
class MessageBuckets:
    """Bucket a file's messages by name and by integer global mesg num.

    Activity ingest reads from `by_name` because fitdecode names every
    standard message. Sleep and monitoring ingest read from `by_num` because
    Garmin's proprietary messages come through as `unknown_NNN` and are not
    addressable by name.
    """

    by_name: dict[str, list[fitdecode.FitDataMessage]] = field(default_factory=dict)
    by_num: dict[int, list[fitdecode.FitDataMessage]] = field(default_factory=dict)
    unknown_counts: dict[int, int] = field(default_factory=dict)
    unknown_samples: dict[int, dict[str, Any]] = field(default_factory=dict)

    def add(self, msg: fitdecode.FitDataMessage) -> None:
        name = msg.name
        num = msg_num(msg)
        if num >= 0:
            self.by_num.setdefault(num, []).append(msg)
        if name.startswith("unknown_"):
            self.unknown_counts[num] = self.unknown_counts.get(num, 0) + 1
            if num not in self.unknown_samples:
                self.unknown_samples[num] = message_to_dict(msg)
            return
        self.by_name.setdefault(name, []).append(msg)

    def get(self, name: str) -> list[fitdecode.FitDataMessage]:
        return self.by_name.get(name, [])

    def get_num(self, num: int) -> list[fitdecode.FitDataMessage]:
        return self.by_num.get(num, [])


def bucket_file(path: Path) -> MessageBuckets:
    """Read a file fully into a MessageBuckets. Activity files are small enough that
    holding everything in RAM is fine; we only need streaming for monitoring files
    when ingesting them sample-by-sample.
    """
    buckets = MessageBuckets()
    for msg in read_messages(path):
        buckets.add(msg)
    return buckets


def iter_messages_for(path: Path, names: Iterable[str]) -> Iterator[fitdecode.FitDataMessage]:
    """Stream only messages whose name is in `names`. Used by monitoring ingest."""
    wanted = set(names)
    for msg in read_messages(path):
        if msg.name in wanted:
            yield msg
