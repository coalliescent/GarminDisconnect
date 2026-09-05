#!/usr/bin/env python3
"""make_icon.py — assemble Resources/AppIcon.icns from the Crestline art.

    python3 tools/make_icon.py          # -> Resources/AppIcon.icns
    make icon                           # same thing

The icon is "Crestline": a bicycle resting on a windswept hillside at dusk,
above a sunset over a bay-side city. Sources and provenance live in
Resources/icon/ (see its README.md). Resources/icon/png/ holds the rendered
size ladder; this script packages those PNGs into the .icns container the
bundle ships as Resources/AppIcon.icns (build.sh copies it in, and
Info.plist's CFBundleIconFile points at it).

Why Python rather than `iconutil`: iconutil is macOS-only, and so was the
Swift generator this replaces, which meant nobody could regenerate or even
check the icon anywhere else. The .icns container is a trivial tagged
format — 'icns' magic, big-endian total length, then (OSType, length,
payload) records — so we write it directly with the standard library. The
PNG payloads are copied byte for byte; nothing here re-encodes the art.

Regenerating the PNGs themselves (only needed if the SVGs change) uses
librsvg, per the deliverable's own instructions:

    cd Resources/icon
    for s in 16 32 64;        do rsvg-convert -w $s -h $s crestline-small.svg -o png/icon-$s.png; done
    for s in 128 256 512 1024; do rsvg-convert -w $s -h $s crestline-512.svg  -o png/icon-$s.png; done

(crestline-small.svg is the simplified variant the designer tuned for 64px
and below; the detailed master is used from 128px up.)
"""

import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (OSType, pixel size). Every one of these takes a PNG payload and is
# understood by macOS 10.8+, comfortably below the bundle's 13.0 floor.
#
#   icp4/icp5  16pt/32pt at 1x
#   ic11..ic14 the @2x rungs (16@2x=32, 32@2x=64, 128@2x=256, 256@2x=512)
#   ic07..ic10 128/256/512 at 1x and 512@2x=1024
#
# icp6 (64px) is deliberately absent: it is inconsistently honoured across
# macOS versions, and ic12 already carries 64px as the 32pt @2x rung.
ICNS_ELEMENTS = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

SOURCE_SIZES = sorted({px for _, px in ICNS_ELEMENTS})

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _png_dimensions(blob, where):
    """(width, height) straight out of the IHDR chunk."""
    if blob[:8] != PNG_MAGIC or blob[12:16] != b"IHDR":
        raise ValueError(f"{where}: not a PNG")
    return struct.unpack(">II", blob[16:24])


def build_icns(pngdir):
    """Return the bytes of an .icns built from pngdir/icon-<size>.png."""
    pngdir = Path(pngdir)

    payloads = {}
    for px in SOURCE_SIZES:
        path = pngdir / f"icon-{px}.png"
        if not path.is_file():
            raise FileNotFoundError(f"missing {path} (expected icon-{px}.png)")
        blob = path.read_bytes()
        got = _png_dimensions(blob, path.name)
        if got != (px, px):
            raise ValueError(
                f"{path.name}: expected {px}x{px}, got {got[0]}x{got[1]}"
            )
        payloads[px] = blob

    body = b"".join(
        struct.pack(">4sI", ostype.encode("ascii"), 8 + len(payloads[px]))
        + payloads[px]
        for ostype, px in ICNS_ELEMENTS
    )
    return struct.pack(">4sI", b"icns", 8 + len(body)) + body


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "-o",
        "--output",
        default=str(ROOT / "Resources/AppIcon.icns"),
        help="where to write the .icns (default: Resources/AppIcon.icns)",
    )
    ap.add_argument(
        "--png-dir",
        default=str(ROOT / "Resources/icon/png"),
        help="directory of icon-<size>.png sources",
    )
    args = ap.parse_args(argv)

    blob = build_icns(args.png_dir)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    print(
        f"wrote {out} ({len(blob):,} bytes, "
        f"{len(ICNS_ELEMENTS)} sizes: {', '.join(str(px) for px in SOURCE_SIZES)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
