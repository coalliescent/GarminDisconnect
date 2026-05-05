#!/bin/bash
# run_tests.sh — compile and run the Database test binary against tiny.db.
#
# This is a separate swiftc invocation from build.sh because the test binary doesn't
# include the AppKit-using sources (main.swift, AppDelegate, MainWindowController) —
# those would just be dead code in a CLI test binary. We compile only Database.swift
# + DatabaseTests.swift and run the resulting executable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null \
       || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
TARGET="${TARGET:-arm64-apple-macos13}"

mkdir -p build

# Build the fixture if it's missing. This is a one-shot — committed fixtures should
# normally be present.
if [[ ! -f Tests/fixtures/tiny.db ]]; then
    echo "Tests/fixtures/tiny.db missing; rebuilding..."
    python3 Tests/build_fixture.py
fi

TEST_BIN="build/DatabaseTests"
echo "compiling $TEST_BIN..."

swiftc \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -module-name GarminDisconnectTests \
    -framework Foundation \
    -lsqlite3 \
    -o "$TEST_BIN" \
    Sources/Data/Database.swift \
    Sources/Data/DateUtil.swift \
    Tests/DatabaseTests.swift \
    Tests/DateUtilTests.swift \
    Tests/TestsMain.swift

echo "running tests..."
"$TEST_BIN"
