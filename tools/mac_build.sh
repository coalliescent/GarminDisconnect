#!/bin/bash
# mac_build.sh — build (and optionally test) this project on a remote Mac.
#
# The viewer half of this repo is macOS-only: Sources/ uses AppKit and WebKit,
# build.sh shells out to `xcrun`/`swiftc`, and Tests/run_tests.sh does the same.
# None of that can run on a Linux box, so day-to-day work there can only ever
# exercise garmin-dump/. This script closes that gap by doing the obvious thing
# — copy the tree to a Mac over ssh and build it in place.
#
# It is deliberately stateless and non-destructive on the remote side: the tree
# is rsync'd into a scratch directory that is never edited by hand, and the
# build artifacts (build/, garmin-dump/.venv) are left there between runs so a
# repeat build is a few seconds rather than a minute.
#
# Usage:
#   tools/mac_build.sh              rsync + build the .app bundle
#   tools/mac_build.sh --tests      ...and run every test suite
#   tools/mac_build.sh --clean      remove build/ and the venv before building
#   tools/mac_build.sh --tests --clean
#
# Configuration. Which Mac this gets built on is deployment-specific, so it is
# never committed: set these in the environment, or in tools/mac_build.local.env
# (git-ignored — copy tools/mac_build.local.env.example and fill it in). The
# environment wins over the file.
#
#   MAC_BUILD_HOST   ssh destination, e.g. build@your-mac.local. Required;
#                    there is deliberately no default.
#   MAC_BUILD_DIR    path on that host (default: ~/build/GarminDisconnect)
#
# Requirements on the remote host: Xcode or the Command Line Tools (for swiftc
# and the macOS SDK) and a python3 >= 3.12 on the *non-interactive* ssh PATH.
# `ssh host <cmd>` runs zsh non-login/non-interactive, which sources only
# ~/.zshenv — if python3 resolves to the system 3.9 there, build.sh's venv step
# fails. Putting `export PATH=/opt/homebrew/bin:$PATH` in ~/.zshenv fixes it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="tools/mac_build.local.env"

RUN_TESTS=false
CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --tests) RUN_TESTS=true ;;
        --clean) CLEAN=true ;;
        -h|--help)
            # Print this file's header comment, however long it happens to be,
            # rather than a hand-maintained line range that drifts as it grows.
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# The build host is read from the environment first, then from $CONFIG, so a
# one-off `MAC_BUILD_HOST=... make mac-build` wins over the checked-in-nowhere
# local file instead of being silently replaced by it.
ENV_HOST="${MAC_BUILD_HOST:-}"
ENV_DIR="${MAC_BUILD_DIR:-}"
if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1091
    . "$CONFIG"
fi
HOST="${ENV_HOST:-${MAC_BUILD_HOST:-}}"
DIR="${ENV_DIR:-${MAC_BUILD_DIR:-~/build/GarminDisconnect}}"

if [ -z "$HOST" ]; then
    cat >&2 <<MSG
mac_build.sh: no build host configured.

Which Mac to build on is deployment-specific, so this repo does not carry a
default. Either export MAC_BUILD_HOST, or create $CONFIG:

    cp $CONFIG.example $CONFIG
    \$EDITOR $CONFIG        # set MAC_BUILD_HOST=user@host

$CONFIG is git-ignored and stays on this machine.
MSG
    exit 1
fi

# Everything git ignores is either a build artifact or a private capture, and
# neither belongs on the wire. .worktrees/ especially: shipping it would copy
# every in-flight branch to the build host.
echo "==> syncing $ROOT -> $HOST:$DIR"
rsync -az --delete \
    --exclude '.git/' \
    --exclude '.worktrees/' \
    --exclude 'build/' \
    --exclude '.venv/' \
    --exclude '__pycache__/' \
    --exclude '*.egg-info/' \
    --exclude '.pytest_cache/' \
    --exclude '.ruff_cache/' \
    --exclude '.DS_Store' \
    ./ "$HOST:$DIR/"

# --delete does not touch paths excluded above, so build/ and the venv survive
# a sync; --clean is how you ask for a cold build.
if $CLEAN; then
    echo "==> cleaning remote build/ and garmin-dump/.venv"
    ssh "$HOST" "cd $DIR && rm -rf build garmin-dump/.venv"
fi

echo "==> building on $HOST"
ssh "$HOST" "cd $DIR && bash build.sh"

if $RUN_TESTS; then
    # Run every suite in one ssh session, but do not let an early failure
    # hide a later one — collect the statuses and report them together.
    echo "==> testing on $HOST"
    ssh "$HOST" "cd $DIR && bash tools/remote_test.sh"
fi

echo
echo "==> done. bundle is at $HOST:$DIR/build/GarminDisconnect.app"
echo "    (unsigned — the build account has no signing identity)"
