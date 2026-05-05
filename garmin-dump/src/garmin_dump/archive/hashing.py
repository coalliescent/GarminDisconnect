"""Streaming SHA-256."""

from __future__ import annotations

import hashlib
from pathlib import Path

CHUNK_SIZE = 1 << 20  # 1 MiB


def sha256_file(path: Path) -> str:
    """Return the lowercase hex SHA-256 of `path`."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(CHUNK_SIZE):
            h.update(chunk)
    return h.hexdigest()
