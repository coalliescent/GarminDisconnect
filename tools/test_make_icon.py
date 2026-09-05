#!/usr/bin/env python3
"""Tests for tools/make_icon.py.

Runnable anywhere python3 is (no venv, no third-party deps, no macOS):

    python3 tools/test_make_icon.py

This is deliberately not part of Tests/run_tests.sh — that suite compiles the
Swift viewer and only runs on macOS, whereas the icon assembler is pure
stdlib Python and should stay verifiable on any machine that can check out
the repo.
"""

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import make_icon  # noqa: E402


def parse_icns(blob):
    """Parse an .icns container into [(ostype, payload), ...].

    Mirrors the format Apple's iconutil emits: a 'icns' magic + big-endian
    total length, then a flat sequence of (4-byte OSType, big-endian length
    *including* the 8-byte element header, payload) records.
    """
    magic, total = struct.unpack(">4sI", blob[:8])
    assert magic == b"icns", f"bad magic {magic!r}"
    assert total == len(blob), f"header claims {total} bytes, file has {len(blob)}"
    out = []
    off = 8
    while off < len(blob):
        ostype, size = struct.unpack(">4sI", blob[off : off + 8])
        assert size >= 8, f"element {ostype!r} claims {size} bytes"
        assert off + size <= len(blob), f"element {ostype!r} overruns the file"
        out.append((ostype.decode("ascii"), blob[off + 8 : off + size]))
        off += size
    return out


def png_size(payload):
    """(width, height) from a PNG's IHDR, without decoding the image."""
    assert payload[:8] == b"\x89PNG\r\n\x1a\n", "payload is not a PNG"
    assert payload[12:16] == b"IHDR", "first PNG chunk is not IHDR"
    return struct.unpack(">II", payload[16:24])


class TestElementTable(unittest.TestCase):
    def test_every_element_maps_to_a_source_png(self):
        for ostype, px in make_icon.ICNS_ELEMENTS:
            with self.subTest(ostype=ostype):
                self.assertIn(px, make_icon.SOURCE_SIZES)

    def test_covers_the_retina_ladder_macos_asks_for(self):
        # 16/32/128/256/512 points, each at 1x and 2x.
        self.assertEqual(
            sorted({px for _, px in make_icon.ICNS_ELEMENTS}),
            [16, 32, 64, 128, 256, 512, 1024],
        )

    def test_ostypes_are_unique_and_four_bytes(self):
        types = [t for t, _ in make_icon.ICNS_ELEMENTS]
        self.assertEqual(len(types), len(set(types)))
        for t in types:
            self.assertEqual(len(t.encode("ascii")), 4, t)


class TestBuildIcns(unittest.TestCase):
    def setUp(self):
        self.pngdir = Path(make_icon.ROOT, "Resources/icon/png")

    def test_source_pngs_exist_at_their_declared_sizes(self):
        for px in make_icon.SOURCE_SIZES:
            path = self.pngdir / f"icon-{px}.png"
            with self.subTest(px=px):
                self.assertTrue(path.is_file(), f"missing {path}")
                self.assertEqual(png_size(path.read_bytes()), (px, px))

    def test_container_is_wellformed_and_lossless(self):
        blob = make_icon.build_icns(self.pngdir)
        elements = parse_icns(blob)
        self.assertEqual(
            [t for t, _ in elements], [t for t, _ in make_icon.ICNS_ELEMENTS]
        )
        for (ostype, payload), (_, px) in zip(elements, make_icon.ICNS_ELEMENTS):
            with self.subTest(ostype=ostype):
                self.assertEqual(png_size(payload), (px, px))
                # Byte-identical to the source: we repackage, never re-encode,
                # so the art in the bundle is exactly what the designer shipped.
                self.assertEqual(payload, (self.pngdir / f"icon-{px}.png").read_bytes())

    def test_missing_source_png_is_a_clear_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError) as ctx:
                make_icon.build_icns(Path(tmp))
            self.assertIn("icon-16.png", str(ctx.exception))

    def test_rejects_a_png_of_the_wrong_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for px in make_icon.SOURCE_SIZES:
                # Every slot filled with the 512px art: only 512 is correct.
                (tmp / f"icon-{px}.png").write_bytes(
                    (self.pngdir / "icon-512.png").read_bytes()
                )
            with self.assertRaises(ValueError) as ctx:
                make_icon.build_icns(tmp)
            self.assertIn("512x512", str(ctx.exception))


class TestCli(unittest.TestCase):
    def test_writes_a_parsable_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp, "AppIcon.icns")
            self.assertEqual(make_icon.main(["-o", str(out)]), 0)
            self.assertGreater(len(parse_icns(out.read_bytes())), 0)

    def test_committed_icns_matches_the_committed_pngs(self):
        # Guards against someone updating the art and forgetting `make icon`.
        committed = Path(make_icon.ROOT, "Resources/AppIcon.icns")
        self.assertTrue(committed.is_file(), f"missing {committed}")
        self.assertEqual(
            committed.read_bytes(),
            make_icon.build_icns(self.__class__.pngdir),
            "Resources/AppIcon.icns is stale — run `make icon`",
        )

    pngdir = Path(make_icon.ROOT, "Resources/icon/png")


if __name__ == "__main__":
    unittest.main(verbosity=2)
