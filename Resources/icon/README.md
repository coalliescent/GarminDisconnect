# App icon — "Crestline"

Added 2026-09-04, replacing the 🚲-emoji placeholder that `tools/make_icon.swift`
used to render.

A bicycle resting on a tall windswept hillside at dusk, overlooking the sunset
over a distant city across a large bay. Backlit illustration: rim-lit frame and
rims, sun glitter on the water, a suspension bridge at the bay mouth, wind-bent
grass and flying seeds, foliage confined to the periphery.

## Provenance

Commissioned through the `swarm` icon-design run `icondesign_bike`; this is the
`fable` deliverable (`claude-fable-5`, run `20260904-152457-make-a-design-deliverabl`),
originally packaged as `~/src/swarm/artifacts/icondesign_bike/fable.zip`. Three
other candidates from the same brief (`glm5.3`, `k3`, `luna`) are in that
directory if this one ever needs re-picking.

## Files

- `crestline-512.svg` — master detailed illustration; source of 128px and up.
- `crestline-small.svg` — simplified bold variant the designer tuned for
  legibility at 64px and below. Same scene and palette, larger sun behind the
  bike, heavier strokes, less detail.
- `png/icon-{16,32,64,128,256,512,1024}.png` — the rendered ladder that
  `tools/make_icon.py` packages into `../AppIcon.icns`.

Everything except `icon-1024.png` came out of the deliverable unmodified; 1024
(the 512pt @2x rung macOS wants and the zip did not carry) was rendered here
from `crestline-512.svg`. The deliverable's other exports — 48/180/192 px,
`favicon.ico`, the presentation sheet — are web/mobile sizes this app has no
use for and were left out.

## Rebuilding

Re-render the PNGs only if the SVGs change (needs librsvg — `rsvg-convert`):

```sh
cd Resources/icon
for s in 16 32 64;          do rsvg-convert -w $s -h $s crestline-small.svg -o png/icon-$s.png; done
for s in 128 256 512 1024;  do rsvg-convert -w $s -h $s crestline-512.svg   -o png/icon-$s.png; done
```

Then repackage the `.icns` (stdlib Python only, works on any OS):

```sh
make icon        # == python3 tools/make_icon.py
python3 tools/test_make_icon.py
```

The test suite fails if `Resources/AppIcon.icns` is stale with respect to these
PNGs, so a forgotten `make icon` will not go unnoticed.

## Known open question

The art is full-bleed: the rounded rect reaches the edge of the canvas. macOS
Big Sur and later expect an app icon's shape to sit at 824/1024 of the canvas
with the remaining margin transparent, so in the Dock this will render slightly
larger than its neighbours. The SVG's corner radius (114/512 = 0.223) already
matches Apple's proportion exactly, so it is only the inset that differs. Left
as delivered because it cannot be eyeballed on a Mac from where this was
assembled — see the GarminDisconnect item filed alongside this commit.
