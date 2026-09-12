# GarminDisconnect

A native macOS viewer for the local Garmin watch archive built by `garmin-dump`,
which is co-located in this repo at [`garmin-dump/`](garmin-dump/) as a
dependency. Together they let you see your own body metrics without ever
talking to Garmin Connect.

## Status

Pre-alpha. macOS Apple Silicon only. Read-only against `~/garmin-archive/garmin.db`.

## Architecture

- **AppKit shell** in Swift, built directly with `swiftc` (no Xcode, no SwiftPM).
- **WKWebView + Plotly.js** for charts. 15 charts across 5 tabs (Overview, Activities,
  Wellness, Sleep, Sync).
- **`import SQLite3`** (system framework) for read-only DB access.
- **Subprocess sync** — clicking "Sync" in the toolbar shells out to `garmin-dump pull`.

## Project layout

```
garmindisconnect/
├── Sources/             AppKit + Swift code (the viewer itself)
├── Resources/web/       index.html, charts.js, vendored Plotly.js
├── Resources/icon/      app icon artwork (SVG sources + rendered PNG ladder)
├── Tests/               unit tests + tiny.db fixture
├── Makefile             thin wrapper: `make`, `make run`, `make test`
├── tools/make_icon.py   packages Resources/icon/png/ into Resources/AppIcon.icns
├── tools/mac_build.sh   build on a remote Mac over ssh (for non-Mac development)
├── build.sh             all real build work (swiftc + stage bundle + embed pylib + launch)
└── garmin-dump/         co-located Python dependency (the sync tool)
    ├── pyproject.toml
    ├── src/garmin_dump/
    └── tests/
```

## Build

Requires macOS Command Line Tools and a Python 3.12+ interpreter on PATH. The
CLT's own `/usr/bin/python3` is 3.9 on most systems and is **not** sufficient
for garmin-dump at runtime; install a newer one via Homebrew:

```sh
brew install python@3  # or any 3.12+; Homebrew's default is fine
brew install libmtp    # required by garmin-dump to talk to the watch
make                   # builds build/GarminDisconnect.app
make run               # same as `make`, plus open the bundle
make clean
make test              # viewer's Swift tests
make test-dep          # garmin-dump's pytest suite
```

`make` installs garmin-dump + its pure-Python deps into the .app bundle itself
(at `Contents/Resources/pylib`), so the bundle is self-contained: the Swift
runner invokes `python3 -m garmin_dump` with `PYTHONPATH` pointing at that dir,
and nothing outside the bundle needs to exist. You can copy the staged .app to
another Mac and it will Just Work as long as that Mac has a 3.12+ `python3`
somewhere standard (`/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`) and
libmtp installed.

The build-time `garmin-dump/.venv` is used only for `pip` (to populate the
bundle) and for `make test-dep` (pytest). The viewer does not touch it at
runtime.

### Building from a machine that isn't a Mac

The viewer cannot be compiled anywhere but macOS — `Sources/` uses AppKit and
WebKit, and both `build.sh` and `Tests/run_tests.sh` shell out to `xcrun`. If
you develop on Linux, `tools/mac_build.sh` rsyncs the tree to a Mac over ssh
and builds it there:

```sh
cp tools/mac_build.local.env.example tools/mac_build.local.env
$EDITOR tools/mac_build.local.env   # set MAC_BUILD_HOST=user@host

make mac-build                     # rsync + build the bundle
make mac-test                      # ...and run all four suites
MAC_BUILD_HOST=you@mac.local make mac-build   # one-off, overrides the file
tools/mac_build.sh --clean --tests # cold build from scratch
```

Which Mac you build on is a property of your machines rather than of this
project, so there is no default and nothing about it is committed:
`MAC_BUILD_HOST` comes from your environment or from
`tools/mac_build.local.env`, which is git-ignored (the `.example` template
beside it is what's tracked). The environment wins over the file.

The remote tree is a scratch copy (`~/build/GarminDisconnect` by default);
`build/` and `garmin-dump/.venv` are kept between runs, so a repeat build takes
seconds. The remote host needs a Swift toolchain and a python3 >= 3.12 on the
*non-interactive* ssh PATH — `ssh host cmd` sources only `~/.zshenv`, so a
Homebrew python needs `export PATH=/opt/homebrew/bin:$PATH` there or build.sh's
venv step picks up the system 3.9 and fails.

`make test-all` runs the viewer, ingester, icon and build-tooling suites
together and reports each one rather than stopping at the first failure. It
needs macOS; it's what `make mac-test` runs on the far side. `make test-tools`
alone (the build tooling's own tests, including a check that no build-host
details have been committed) runs anywhere python3 does.

## Usage

```sh
make run                                                    # uses ~/garmin-archive/garmin.db
GARMIN_DISCONNECT_DB=/path/to/garmin.db make run            # custom archive
```

The "Sync" button in the toolbar runs `garmin-dump pull` against your watch and
refreshes all charts when the pull completes. Configure the path to garmin-dump in
the Settings panel if it's not on `$PATH`.

## Critical: empty archive on first launch

If `~/garmin-archive/garmin.db` doesn't exist or has no data, you'll see a welcome
card. Click "Sync" in the viewer's toolbar — that runs `garmin-dump pull` against
your watch and refreshes all charts when it completes.

## Known data gap (2026-04-08)

The viewer's **Wellness** and **Sleep** tabs are mostly empty against the Garmin
Instinct 3 - 45mm because garmin-dump's parser doesn't yet decode the
proprietary FIT message types this watch uses (the dominant `unknown_233` and
`unknown_279` messages from monitor and activity files, plus the unknown sleep
file message types). Steps, distance, and active calories DO populate; HR,
stress, body battery, sleep stages, and most other wellness telemetry are
parsed-as-unknown and not surfaced.

This is upstream-of-the-viewer work — see
[`garmin-dump/PARSER_NOTES.md`](garmin-dump/PARSER_NOTES.md) for the
investigation kickoff and the Path B plan.

## License

MIT
