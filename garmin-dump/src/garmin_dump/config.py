"""Configuration loading.

Resolution order (later overrides earlier):
    1. Built-in defaults
    2. ~/.config/garmin-dump/config.toml (or `--config PATH`)
    3. Environment variables (GARMIN_DUMP_*)
    4. CLI flags (passed in by `cli.py`)
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path

from platformdirs import user_config_dir

CONFIG_DIRNAME = "garmin-dump"
CONFIG_FILENAME = "config.toml"

DEFAULT_ARCHIVE_ROOT = Path.home() / "garmin-archive"
DEFAULT_RETENTION_DAYS = 30
MIN_RETENTION_DAYS = 30  # safety floor; --force-young is the only way to go below


@dataclass(frozen=True)
class Config:
    """Resolved runtime configuration."""

    archive_root: Path = DEFAULT_ARCHIVE_ROOT
    retention_days: int = DEFAULT_RETENTION_DAYS
    config_path: Path | None = None
    verbose: bool = False
    quiet: bool = False
    json_output: bool = False

    @property
    def db_path(self) -> Path:
        return self.archive_root / "garmin.db"

    @property
    def devices_dir(self) -> Path:
        return self.archive_root / "devices"

    @property
    def tmp_dir(self) -> Path:
        return self.archive_root / "tmp"

    @property
    def logs_dir(self) -> Path:
        return self.archive_root / "logs"


def default_config_path() -> Path:
    return Path(user_config_dir(CONFIG_DIRNAME)) / CONFIG_FILENAME


def load_config(
    *,
    config_path: Path | None = None,
    archive_root: Path | None = None,
    verbose: bool = False,
    quiet: bool = False,
    json_output: bool = False,
) -> Config:
    """Build a Config from the resolution chain.

    `config_path` and `archive_root` come from CLI flags. Anything not set falls back to
    env vars (`GARMIN_DUMP_CONFIG`, `GARMIN_DUMP_ARCHIVE`), then to the TOML file, then
    to built-in defaults.
    """
    cfg = Config(verbose=verbose, quiet=quiet, json_output=json_output)

    # Resolve config file path
    cfg_path = (
        config_path
        or _env_path("GARMIN_DUMP_CONFIG")
        or default_config_path()
    )
    if cfg_path.is_file():
        cfg = _apply_toml(cfg, cfg_path)
        cfg = replace(cfg, config_path=cfg_path)

    # Env override for archive root
    if (env_archive := _env_path("GARMIN_DUMP_ARCHIVE")) is not None:
        cfg = replace(cfg, archive_root=env_archive)

    # CLI flag wins over everything for archive root
    if archive_root is not None:
        cfg = replace(cfg, archive_root=archive_root.expanduser())

    # Normalize the archive root
    cfg = replace(cfg, archive_root=cfg.archive_root.expanduser().resolve())

    return cfg


def _env_path(key: str) -> Path | None:
    val = os.environ.get(key)
    return Path(val).expanduser() if val else None


def _apply_toml(cfg: Config, path: Path) -> Config:
    with path.open("rb") as f:
        data = tomllib.load(f)
    archive = data.get("archive", {})
    retention = data.get("retention", {})

    new_archive_root = cfg.archive_root
    if (root := archive.get("root")) is not None:
        new_archive_root = Path(root).expanduser()

    new_retention = cfg.retention_days
    if (days := retention.get("days")) is not None:
        if not isinstance(days, int) or days < MIN_RETENTION_DAYS:
            raise ValueError(
                f"retention.days in {path} must be an integer >= {MIN_RETENTION_DAYS}; got {days!r}"
            )
        new_retention = days

    return replace(cfg, archive_root=new_archive_root, retention_days=new_retention)


def ensure_dirs(cfg: Config) -> None:
    """Create the archive directory tree if it doesn't exist."""
    for d in (cfg.archive_root, cfg.devices_dir, cfg.tmp_dir, cfg.logs_dir):
        d.mkdir(parents=True, exist_ok=True)


# Silence linter for unused imports that document the dataclass fields
_ = field
