"""The schema-version contract between garmin-dump and the Swift viewer.

garmin-dump owns `PRAGMA user_version`; the GarminDisconnect viewer reads it and
refuses to open a database it doesn't understand. Those two numbers live in
different languages and different build systems, so nothing but a test keeps
them honest.

This has already bitten once: garmin-dump went to schema 3 for the monitoring
rollup repair while `Database.swift` still demanded an exact 2, and the app
stopped opening freshly reparsed archives with "GarminDisconnect expects db
version 2". The Swift side now accepts a range; these tests assert the Python
side stays inside it.

The viewer is not built on every machine that runs this suite, so the checks
skip when the Swift source isn't there.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from garmin_dump.db.migrations import CURRENT_VERSION, MIGRATIONS

DATABASE_SWIFT = (
    Path(__file__).resolve().parents[3] / "Sources" / "Data" / "Database.swift"
)


def _swift_int(name: str) -> int:
    """Read a `let <name>: Int32 = <n>` constant out of Database.swift."""
    if not DATABASE_SWIFT.is_file():
        pytest.skip(f"viewer source not present at {DATABASE_SWIFT}")
    source = DATABASE_SWIFT.read_text(encoding="utf-8")
    match = re.search(rf"let\s+{re.escape(name)}\s*:\s*Int32\s*=\s*(\d+)", source)
    if match is None:
        pytest.fail(
            f"{name} is no longer declared as `let {name}: Int32 = <n>` in "
            f"{DATABASE_SWIFT.name}; this contract test needs updating alongside it"
        )
    return int(match.group(1))


def test_viewer_accepts_the_version_garmin_dump_writes() -> None:
    """The headline invariant: a DB garmin-dump just migrated must open."""
    newest = _swift_int("GARMIN_DUMP_SCHEMA_VERSION")
    assert CURRENT_VERSION <= newest, (
        f"garmin-dump writes user_version={CURRENT_VERSION} but the viewer only "
        f"understands up to {newest}. Bump GARMIN_DUMP_SCHEMA_VERSION in "
        f"Sources/Data/Database.swift (and say what changed in its doc comment)."
    )


def test_viewer_floor_is_not_above_what_garmin_dump_writes() -> None:
    oldest = _swift_int("GARMIN_DUMP_MIN_SCHEMA_VERSION")
    assert oldest <= CURRENT_VERSION, (
        f"the viewer refuses anything below user_version={oldest}, but garmin-dump "
        f"writes {CURRENT_VERSION}"
    )


def test_the_viewers_own_migration_target_is_reachable() -> None:
    """The viewer must never stamp a version garmin-dump hasn't defined.

    `VIEWER_MIGRATES_TO` is how far the viewer will advance a database on its
    own. If it ever exceeded garmin-dump's ladder, the viewer would mark
    migrations as applied that never ran — which is exactly how the v3 repair
    would get skipped and the bad step counts preserved.
    """
    migrates_to = _swift_int("VIEWER_MIGRATES_TO")
    assert migrates_to <= CURRENT_VERSION, (
        f"the viewer stamps user_version={migrates_to}, beyond garmin-dump's "
        f"{CURRENT_VERSION}"
    )
    defined = {target for target, _ in MIGRATIONS}
    assert migrates_to in defined, (
        f"the viewer stamps user_version={migrates_to}, which is not a version "
        f"garmin-dump defines a migration for ({sorted(defined)})"
    )


def test_migrations_ladder_is_contiguous_and_ends_at_current() -> None:
    """A gap would let `apply_migrations` skip a step it should have run."""
    targets = [target for target, _ in MIGRATIONS]
    assert targets == sorted(targets), f"MIGRATIONS is out of order: {targets}"
    assert targets == list(range(1, len(targets) + 1)), (
        f"MIGRATIONS should be 1..N with no gaps, got {targets}"
    )
    assert targets[-1] == CURRENT_VERSION, (
        f"CURRENT_VERSION is {CURRENT_VERSION} but the last migration targets "
        f"{targets[-1]}"
    )
