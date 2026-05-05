#!/bin/bash
# build.sh — build GarminDisconnect.app end-to-end.
#
# This script is the single entry point for turning a fresh checkout into a
# runnable .app bundle. It does, in order:
#
#   1. Install the co-located garmin-dump Python dep if its venv is missing
#      (python3 -m venv + pip install -e garmin-dump). Skipped if already set
#      up. Does NOT attempt to install libmtp; that's a brew-level concern
#      the viewer flags at runtime if the user clicks Sync without it.
#   2. Compile every Sources/**/*.swift into build/GarminDisconnect.
#      Multi-file single-module compile is the only option under Command Line
#      Tools (no Xcode, no SwiftPM).
#   3. Stage build/GarminDisconnect.app: binary + Info.plist + Resources/.
#
# With --run, also quits any existing instance and `open`s the bundle with
# GARMIN_DISCONNECT_DB passed through (macOS `open` strips the launching shell
# environment by default, so the explicit --env passthrough is required).
#
# Usage:
#   ./build.sh              build + bundle
#   ./build.sh --run        build + bundle + open the bundle
#
# Env vars:
#   GARMIN_DISCONNECT_DB    absolute-or-relative path to an archive .db; only
#                           consulted with --run. Resolved to absolute before
#                           being handed to `open --env`.
#   TARGET                  swiftc target triple (default arm64-apple-macos13)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

RUN=false
for arg in "$@"; do
    case "$arg" in
        --run) RUN=true ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

BIN_NAME="GarminDisconnect"
APP_NAME="$BIN_NAME.app"
BUILD_DIR="$ROOT/build"
BIN_PATH="$BUILD_DIR/$BIN_NAME"
APP_PATH="$BUILD_DIR/$APP_NAME"
APP_MACOS="$APP_PATH/Contents/MacOS"
APP_RES="$APP_PATH/Contents/Resources"

# ============================================================================
# 1. garmin-dump dev venv (build-time pip only; NOT used at runtime)
# ============================================================================
#
# The bundled app invokes garmin-dump via a system python3 with PYTHONPATH
# pointing at an in-bundle payload (step 4 below). We still need a pip at
# build time to produce that payload, and `make test-dep` wants the venv for
# pytest. So we set up .venv once and reuse it.
#
# Important: nothing the user runs at runtime depends on this venv. If the
# bundle is copied to another machine, only the in-bundle payload matters.
if [[ ! -x garmin-dump/.venv/bin/pip ]]; then
    if [[ ! -d garmin-dump ]]; then
        echo "error: garmin-dump/ not found at $ROOT/garmin-dump" >&2
        exit 1
    fi
    echo "creating build-time venv at garmin-dump/.venv (first-time setup)..."
    python3 -m venv garmin-dump/.venv
    garmin-dump/.venv/bin/pip install --quiet --upgrade pip
    garmin-dump/.venv/bin/pip install --quiet -e garmin-dump

    # libmtp isn't something we install, but it IS required at pull time. Warn
    # now so the user doesn't discover the missing dep only when Sync fails.
    if ! command -v mtp-detect >/dev/null 2>&1 \
         && [[ ! -x /opt/homebrew/bin/mtp-detect ]] \
         && [[ ! -x /usr/local/bin/mtp-detect ]]; then
        echo "warning: libmtp not on PATH — run 'brew install libmtp' before pulling" >&2
    fi
fi

# ============================================================================
# 2. Swift compile
# ============================================================================
#
# Resolve the macOS SDK. xcrun is preferred (it picks up the right SDK
# regardless of CLT vs full Xcode); fall back to the well-known CLT path.
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null \
       || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
if [[ ! -d "$SDK" ]]; then
    echo "error: macOS SDK not found at $SDK" >&2
    echo "       install Command Line Tools: xcode-select --install" >&2
    exit 1
fi

# Pinned target. Anything ≥ macOS 13 ships WKWebView and the SQLite3 module map
# we need.
TARGET="${TARGET:-arm64-apple-macos13}"

# Sanity check for the SwiftBridging redefinition issue documented in the
# user's ~/.claude/CLAUDE.md. If both modulemap files still exist, swiftc will
# fail with "redefinition of module 'SwiftBridging'" and the user has to
# rename one of them.
SWIFTBRIDGING_DUP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f "$SWIFTBRIDGING_DUP" \
      && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    echo "warning: SwiftBridging module redefinition is likely. If the build fails with" >&2
    echo "         'redefinition of module SwiftBridging', run:" >&2
    echo "    sudo mv $SWIFTBRIDGING_DUP $SWIFTBRIDGING_DUP.bak" >&2
fi

mkdir -p "$BUILD_DIR"

# Find every Swift source under Sources/ in deterministic order so the build is
# reproducible across runs and across machines. macOS ships bash 3.2, which has
# no `mapfile`, so we use a while-read loop into a positional-args list.
# Filenames containing newlines are not supported (and would be a horrible idea
# anyway).
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("$f")
done < <(find Sources -name '*.swift' -print | LC_ALL=C sort)

if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "error: no .swift files found under Sources/" >&2
    exit 1
fi

echo "building $BIN_NAME (${#SOURCES[@]} sources, target $TARGET)..."

swiftc \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -module-name GarminDisconnect \
    -framework AppKit \
    -framework WebKit \
    -framework Foundation \
    -lsqlite3 \
    -o "$BIN_PATH" \
    "${SOURCES[@]}"

echo "built $BIN_PATH"

# ============================================================================
# 3. Stage .app bundle
# ============================================================================
#
# We wipe Resources/web before re-copying. macOS `cp -R src dst/` merges on top
# of an existing destination, but it's been seen to occasionally leave old
# files in place when src/dst live on a Shared Files mount — resulting in
# stale bootstrap.js / charts.js inside the bundle even after the source has
# been edited. The rm forces a clean copy.
mkdir -p "$APP_MACOS" "$APP_RES"
cp "$BIN_PATH" "$APP_MACOS/$BIN_NAME"
cp Resources/Info.plist "$APP_PATH/Contents/"
rm -rf "$APP_RES/web"
if [[ -d Resources/web ]]; then cp -R Resources/web "$APP_RES/"; fi
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP_RES/"; fi

# ============================================================================
# 3a. Embed garmin-dump Python payload into the bundle
# ============================================================================
#
# `pip install --target` produces a flat, importable package tree with no
# venv-style absolute shebangs baked in. All of garmin-dump's runtime deps
# (typer, rich, fitdecode, platformdirs, click, pygments, shellingham, …) are
# pure Python, so this payload is portable across machines with a compatible
# python3 (>=3.12) on PATH. The Swift runner spawns `python3 -m garmin_dump`
# with PYTHONPATH=<this dir> — no garmin-dump binary, no shebangs.
#
# We rm the target dir first because pip --target complains about pre-existing
# package files from prior builds.
PYLIB="$APP_RES/pylib"
rm -rf "$PYLIB"
mkdir -p "$PYLIB"
echo "installing garmin-dump into bundle pylib ($PYLIB)..."
garmin-dump/.venv/bin/pip install --quiet --target "$PYLIB" "$ROOT/garmin-dump"

# `pip --target` also drops console-script wrappers in a bin/ subdir. Those
# wrappers still bake in the calling interpreter's absolute path in their
# shebang, which is exactly the non-portability we're trying to avoid. The
# Swift runner doesn't invoke them (we use `python3 -m garmin_dump`), so
# remove bin/ outright — leaving it would just be misleading debug bait.
rm -rf "$PYLIB/bin"

# Bump mtime on the bundle so Launch Services re-reads Info.plist.
touch "$APP_PATH"
echo "staged $APP_PATH"

if ! $RUN; then
    exit 0
fi

# ============================================================================
# 4. --run: quit existing instance, resolve env, launch
# ============================================================================
#
# macOS `open --env` is silently a no-op when the target app is already
# running — it just brings the existing window forward, and that existing
# process keeps whatever environment it was launched with. So without an
# explicit quit, `./build.sh --run` after a previous `--run` would just
# refresh focus and ignore the new GARMIN_DISCONNECT_DB. We use osascript so
# the app gets a clean quit (saves window state, releases the DB cleanly);
# if osascript fails or the app isn't running, that's fine.
if pgrep -xq "$BIN_NAME"; then
    echo "quitting existing $APP_NAME instance..."
    osascript -e "quit app \"$BIN_NAME\"" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if ! pgrep -xq "$BIN_NAME"; then break; fi
        sleep 0.1
    done
fi

if [[ -n "${GARMIN_DISCONNECT_DB:-}" ]]; then
    # Expand ~, then resolve to absolute. python3 is the most portable way to
    # do `os.path.abspath` without requiring the file to already exist.
    ABS_DB="$(python3 -c '
import os, sys
p = os.path.expanduser(sys.argv[1])
print(p if os.path.isabs(p) else os.path.abspath(p))
' "$GARMIN_DISCONNECT_DB")"

    if [[ -z "$ABS_DB" ]]; then
        echo "error: failed to resolve GARMIN_DISCONNECT_DB=$GARMIN_DISCONNECT_DB" >&2
        exit 1
    fi

    echo "launching $APP_NAME"
    echo "  GARMIN_DISCONNECT_DB raw:      $GARMIN_DISCONNECT_DB"
    echo "  GARMIN_DISCONNECT_DB resolved: $ABS_DB"
    echo "  app path:                      $APP_PATH"

    if [[ ! -e "$ABS_DB" ]]; then
        echo "warning: $ABS_DB does not exist (the app will show its welcome view)" >&2
    fi

    open --env "GARMIN_DISCONNECT_DB=$ABS_DB" "$APP_PATH"
else
    echo "launching $APP_NAME (no GARMIN_DISCONNECT_DB override; using default)"
    open "$APP_PATH"
fi
