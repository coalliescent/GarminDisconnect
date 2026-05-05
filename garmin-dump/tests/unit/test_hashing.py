"""Tests for streaming SHA-256 helper."""

from __future__ import annotations

import hashlib
from pathlib import Path

from garmin_dump.archive.hashing import sha256_file


def test_sha256_matches_hashlib(tmp_path: Path) -> None:
    blob = b"hello garmin\n" * 100_000
    p = tmp_path / "blob.bin"
    p.write_bytes(blob)
    assert sha256_file(p) == hashlib.sha256(blob).hexdigest()


def test_sha256_empty_file(tmp_path: Path) -> None:
    p = tmp_path / "empty"
    p.write_bytes(b"")
    assert sha256_file(p) == hashlib.sha256(b"").hexdigest()
