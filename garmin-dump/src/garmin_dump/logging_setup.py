"""Logging configuration.

Two sinks:
    1. A Rich-based console handler that respects `--verbose` / `--quiet` / `--json`.
    2. A JSONL file handler under `<archive>/logs/garmin-dump-YYYY-MM-DD.jsonl`.

The JSONL log is one record per line so that a future viewer (or `jq`) can grep it
without dragging in a logging library.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
from datetime import UTC, date, datetime
from pathlib import Path

from rich.logging import RichHandler

LOGGER_NAME = "garmin_dump"


class JsonlFormatter(logging.Formatter):
    """Format LogRecords as one JSON object per line."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        # Include any extra= fields
        for k, v in record.__dict__.items():
            if k in _STD_LOGRECORD_FIELDS or k.startswith("_"):
                continue
            try:
                json.dumps(v)
                payload[k] = v
            except (TypeError, ValueError):
                payload[k] = repr(v)
        return json.dumps(payload, default=str)


_STD_LOGRECORD_FIELDS = frozenset(
    {
        "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
        "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
        "created", "msecs", "relativeCreated", "thread", "threadName",
        "processName", "process", "message", "asctime", "taskName",
    }
)


def setup_logging(
    *,
    verbose: bool,
    quiet: bool,
    logs_dir: Path | None = None,
) -> logging.Logger:
    """Configure the root garmin_dump logger and return it.

    Safe to call multiple times — handlers are replaced, not duplicated.
    """
    logger = logging.getLogger(LOGGER_NAME)
    logger.handlers.clear()
    logger.propagate = False

    if quiet:
        console_level = logging.WARNING
    elif verbose:
        console_level = logging.DEBUG
    else:
        console_level = logging.INFO
    logger.setLevel(logging.DEBUG)  # always-on at logger; handlers gate

    console = RichHandler(
        rich_tracebacks=True,
        show_time=False,
        show_path=verbose,
        markup=False,
    )
    console.setLevel(console_level)
    logger.addHandler(console)

    if logs_dir is not None:
        logs_dir.mkdir(parents=True, exist_ok=True)
        today = date.today().isoformat()
        jsonl_path = logs_dir / f"garmin-dump-{today}.jsonl"
        file_handler = logging.FileHandler(jsonl_path, encoding="utf-8")
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(JsonlFormatter())
        logger.addHandler(file_handler)

    return logger


def get_logger() -> logging.Logger:
    return logging.getLogger(LOGGER_NAME)
