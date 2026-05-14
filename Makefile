# GarminDisconnect — thin wrapper around build.sh.
#
# All the real work (installing the garmin-dump venv, compiling Swift, staging
# the .app bundle, launching with env passthrough) lives in build.sh. These
# targets exist only so `make` / `make run` / `make clean` / `make test` keep
# working as muscle-memory entry points.

ROOT      := $(shell pwd)
BUILD_DIR := $(ROOT)/build

.PHONY: all bundle run clean test test-dep icon help

all: bundle

help:
	@echo "GarminDisconnect — make targets"
	@echo "  make             build and stage GarminDisconnect.app"
	@echo "  make run         build, stage, and open the bundle"
	@echo "  make icon        regenerate Resources/AppIcon.icns from tools/make_icon.swift"
	@echo "  make clean       rm -rf build/"
	@echo "  make test        run viewer unit tests against Tests/fixtures/tiny.db"
	@echo "  make test-dep    run garmin-dump's pytest suite"
	@echo ""
	@echo "build.sh installs garmin-dump/.venv automatically on first run."
	@echo "libmtp is NOT installed automatically — 'brew install libmtp' if"
	@echo "the viewer shows a 'libmtp is not installed' dialog on Sync."

bundle:
	@bash build.sh

run:
	@bash build.sh --run

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "cleaned $(BUILD_DIR)"

test:
	@bash Tests/run_tests.sh

# Regenerate the app icon. The script renders 🚲 over a dark gradient,
# applies CICrystallize, and bundles every iconset size into AppIcon.icns.
# The intermediate .iconset/ directory is left in place after the run for
# inspection.
icon:
	@swift tools/make_icon.swift

# garmin-dump's own pytest suite — separate concern from the viewer tests.
# The venv is created by build.sh on first `make`; this target assumes it
# already exists (and reuses it as-is, only ensuring pytest is installed).
test-dep:
	@if [ ! -x garmin-dump/.venv/bin/pytest ]; then \
	  echo "garmin-dump venv not set up; running 'make' first..."; \
	  bash build.sh; \
	  garmin-dump/.venv/bin/pip install --quiet pytest; \
	fi
	@cd garmin-dump && .venv/bin/pytest -q tests/
