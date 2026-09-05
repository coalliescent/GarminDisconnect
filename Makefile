# GarminDisconnect — thin wrapper around build.sh.
#
# All the real work (installing the garmin-dump venv, compiling Swift, staging
# the .app bundle, launching with env passthrough) lives in build.sh. These
# targets exist only so `make` / `make run` / `make clean` / `make test` keep
# working as muscle-memory entry points.

ROOT      := $(shell pwd)
BUILD_DIR := $(ROOT)/build

.PHONY: all bundle run clean test test-dep icon test-icon help

all: bundle

help:
	@echo "GarminDisconnect — make targets"
	@echo "  make             build and stage GarminDisconnect.app"
	@echo "  make run         build, stage, and open the bundle"
	@echo "  make icon        repackage Resources/AppIcon.icns from Resources/icon/png/"
	@echo "  make clean       rm -rf build/"
	@echo "  make test        run viewer unit tests against Tests/fixtures/tiny.db"
	@echo "  make test-dep    run garmin-dump's pytest suite"
	@echo "  make test-icon   run the icon assembler's tests (no macOS needed)"
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

# Repackage the app icon. tools/make_icon.py writes the .icns container
# directly from the PNG ladder in Resources/icon/png/ using nothing but the
# standard library — no iconutil, no Swift, so it runs (and is tested) on any
# machine, not just a Mac. See Resources/icon/README.md for the artwork's
# provenance and how to re-render the PNGs from the SVG sources.
icon:
	@python3 tools/make_icon.py

# The icon assembler's own tests. Pure stdlib Python; unlike `make test` these
# do not need macOS. Also asserts the committed .icns is in sync with the
# committed PNGs, i.e. that nobody forgot to run `make icon`.
test-icon:
	@python3 tools/test_make_icon.py

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
