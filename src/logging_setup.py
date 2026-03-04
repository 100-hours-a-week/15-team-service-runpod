import logging
import os
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

TRUE_VALUES = {"1", "true", "yes", "on"}
DEFAULT_LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"
DEFAULT_LOG_DATE_FORMAT = "%Y-%m-%dT%H:%M:%S%z"


def get_bool_env(name: str, default: bool) -> bool:
    return str(os.getenv(name, str(default))).strip().lower() in TRUE_VALUES


def _get_int_env(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _get_log_level() -> int:
    level_name = str(os.getenv("LOGS_LEVEL", "INFO")).strip().upper()
    level = logging.getLevelName(level_name)
    if isinstance(level, int):
        return level
    return logging.INFO


def configure_logging() -> None:
    root_logger = logging.getLogger()
    root_logger.setLevel(_get_log_level())

    for handler in list(root_logger.handlers):
        root_logger.removeHandler(handler)
        try:
            handler.close()
        except Exception:
            pass

    formatter = logging.Formatter(DEFAULT_LOG_FORMAT, datefmt=DEFAULT_LOG_DATE_FORMAT)

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    root_logger.addHandler(stream_handler)

    file_path = os.getenv("LOGS_FILE_PATH", "/tmp/worker.log")
    max_bytes = _get_int_env("LOGS_FILE_MAX_BYTES", 20 * 1024 * 1024)
    backup_count = _get_int_env("LOGS_FILE_BACKUP_COUNT", 4)

    if max_bytes < 1:
        max_bytes = 20 * 1024 * 1024
    if backup_count < 0:
        backup_count = 4

    Path(file_path).parent.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(
        file_path,
        maxBytes=max_bytes,
        backupCount=backup_count,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    root_logger.addHandler(file_handler)
