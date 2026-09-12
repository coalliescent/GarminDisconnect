#!/bin/bash
# remote_test.sh — run every test suite this repo has, on a Mac.
#
# Split out of mac_build.sh so it is a single ssh command on the far side, and
# so it can also be run directly on a Mac checkout. Unlike `make test`, this
# does not stop at the first failing suite: a red viewer suite should not hide
# the state of the ingester's. Exits non-zero if any suite failed.
#
# Usage:  bash tools/remote_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

declare -a NAMES=()
declare -a CODES=()

run() {
    local name="$1"; shift
    echo
    echo "===== $name ====="
    "$@"
    local code=$?
    NAMES+=("$name")
    CODES+=("$code")
}

run "viewer (Swift)"      bash Tests/run_tests.sh
run "garmin-dump (pytest)" make test-dep
run "icon assembler"       make test-icon
run "build tooling"        make test-tools

echo
echo "===== summary ====="
fail=0
for i in "${!NAMES[@]}"; do
    if [[ "${CODES[$i]}" -eq 0 ]]; then
        printf '  ok    %s\n' "${NAMES[$i]}"
    else
        printf '  FAIL  %s (exit %s)\n' "${NAMES[$i]}" "${CODES[$i]}"
        fail=1
    fi
done
exit "$fail"
