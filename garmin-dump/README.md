# garmin-dump

Direct USB workout & wellness archiver for the Garmin Instinct 3 Solar (and other Garmin
MTP devices). Reads FIT files off the watch via libmtp, archives them on a macOS host,
indexes the data into SQLite for analytics, and (carefully) reclaims storage on the
watch — all without depending on Garmin Connect.

## Why

Garmin Connect requires granting third-party apps insecure access tokens to retrieve a
user's own workout and body-metric data. This tool sidesteps Garmin Connect entirely.

## Status

Alpha. macOS Apple Silicon only. Read-only with respect to the watch (deletes are
explicit, gated, and never touch files younger than 30 days).

## Install

Prerequisites:

```sh
brew install libmtp
brew install uv          # if you don't already have it
```

Project install:

```sh
cd "$(pwd)"
uv sync
uv run garmin-dump --help
```

To install as a global CLI on your `$PATH`:

```sh
uv tool install --from . garmin-dump
# Add ~/.local/bin to your PATH if it isn't already
```

## Usage

```sh
garmin-dump doctor              # preflight checks (toolchain, locks, archive, db)
garmin-dump status              # plug in the watch and see what would sync
garmin-dump pull                # sync new files (default scope: activity+monitor+sleep+metrics)
garmin-dump pull --full         # also mirror everything else under /GARMIN/
garmin-dump pull --dry-run      # show what would be transferred, don't transfer
garmin-dump prune               # delete >30-day verified files (manual confirm)
garmin-dump prune --yes         # skip the confirm prompt, suitable for launchd
garmin-dump trash               # empty .Trashes on the device
garmin-dump ingest --reparse    # re-parse archived FIT files into SQLite
garmin-dump info db             # schema version, table row counts, db path
garmin-dump info archive        # archive bytes, file counts, parser coverage
garmin-dump export --table activities --format csv --since 2026-01-01 > runs.csv
garmin-dump version             # libmtp / fitdecode / schema versions
```

Default archive root: `~/garmin-archive/`. Override with `--archive PATH` or
`GARMIN_DUMP_ARCHIVE=...`.

## Critical: quit Garmin Express first

macOS only allows one process to hold an MTP device at a time. If Garmin Express, its
background daemon, Image Capture, Photos, Android File Transfer, OpenMTP, or even Finder
(after browsing the device once) is running, libmtp cannot enumerate the watch. The tool
will detect this and refuse to run with a remediation message — it will **not** kill the
offending process.

To find offenders manually:

```sh
pgrep -lf 'Garmin|GarminCore|GarminConnect|Image Capture|Android File Transfer|OpenMTP'
```

## Failure triage

| Symptom | Likely cause | Fix |
|---|---|---|
| `mtp-detect: no devices` | Garmin Express still running | `pgrep -lf garmin` then quit those apps |
| `mtp-detect: no devices` | Watch not in MTP mode | Watch: Settings → System → USB Mode → MTP, replug |
| `LIBMTP PANIC: Could not get list of folders` | libmtp / kext mismatch | `brew upgrade libmtp` |
| Hangs on first `mtp-files` | macOS exclusive-access lock | Quit Image Capture, Photos, AFT, OpenMTP, Finder |
| `sync_log` rows stuck `pending` | Per-file failure | `garmin-dump pull -v`, inspect `error_message` |
| `fitdecode.FitError` on one file | Truncated FIT (interrupted activity) | File logged + skipped; raw `.fit` retained |
| Schema migration error | DB version mismatch | `garmin-dump info db`; worst case: delete `garmin.db` + `ingest --reparse` |
| Doesn't enumerate at all | Charging-only USB-C cable | Try a known data cable |

## Safety net

The 30-day retention rule defends against `garmin-dump`, not against the watch's own
storage limits. **The actual safety net is "sync regularly"** — if you go a month
without running `pull`, the watch may auto-delete its own oldest files when it fills up.

## Out of scope

No frontend, no Garmin Connect interop, no upload-to-watch, no FIT file repair, no ANT+,
no Linux/Windows, no encrypted archive (use FileVault), no cron/launchd plist shipped
in-box (the tool itself is launchd-friendly via `pull --yes`).

## License

MIT
