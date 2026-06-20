"""Unit tests for runtime_config.get_llm_provider.

All tests use a mock Session — no DB, no I/O.
The module-level cache is reset before and after each test via the autouse
fixture so tests are fully independent regardless of execution order.
"""

import time
from collections.abc import Generator
from unittest.mock import MagicMock

import pytest
import structlog.testing

import app.src.core.runtime_config as rc
from app.src.core.runtime_config import CACHE_TTL_SECONDS, get_llm_provider


@pytest.fixture(autouse=True)
def reset_cache() -> Generator[None, None, None]:
    rc._reset_cache()
    yield
    rc._reset_cache()


# ── helpers ───────────────────────────────────────────────────────────────────


def _db_with_value(value: str) -> MagicMock:
    row = MagicMock()
    row.value = value
    db = MagicMock()
    db.get.return_value = row
    return db


def _db_no_row() -> MagicMock:
    db = MagicMock()
    db.get.return_value = None
    return db


def _db_error() -> MagicMock:
    db = MagicMock()
    db.get.side_effect = RuntimeError("connection refused")
    return db


# ── cache behaviour ───────────────────────────────────────────────────────────


def test_cache_miss_queries_db() -> None:
    db = _db_with_value("bedrock")
    result = get_llm_provider(db)
    assert result == "bedrock"
    db.get.assert_called_once()


def test_cache_hit_within_ttl_does_not_query_db() -> None:
    db = _db_with_value("bedrock")
    get_llm_provider(db)
    db.get.reset_mock()

    get_llm_provider(db)

    db.get.assert_not_called()


def test_cache_hit_returns_previously_fetched_value() -> None:
    get_llm_provider(_db_with_value("bedrock"))
    # Second call uses a different db mock; if cache is working, this mock is never hit
    result = get_llm_provider(_db_with_value("anthropic_api"))
    assert result == "bedrock"


def test_expired_cache_re_queries_db() -> None:
    db = _db_with_value("bedrock")
    get_llm_provider(db)
    db.get.reset_mock()

    rc._cached_at = time.monotonic() - CACHE_TTL_SECONDS - 1

    get_llm_provider(db)

    db.get.assert_called_once()


# ── validation ────────────────────────────────────────────────────────────────


def test_valid_bedrock_returned() -> None:
    assert get_llm_provider(_db_with_value("bedrock")) == "bedrock"


def test_valid_anthropic_api_returned() -> None:
    assert get_llm_provider(_db_with_value("anthropic_api")) == "anthropic_api"


def test_invalid_db_value_falls_back_to_default() -> None:
    with structlog.testing.capture_logs() as logs:
        result = get_llm_provider(_db_with_value("openai"))

    assert result == "anthropic_api"
    assert any(
        e.get("log_level") == "warning" and "invalid_value" in e.get("event", "")
        for e in logs
    )


def test_invalid_db_value_logs_the_bad_value() -> None:
    with structlog.testing.capture_logs() as logs:
        get_llm_provider(_db_with_value("typo_value"))

    warning = next(e for e in logs if "invalid_value" in e.get("event", ""))
    assert warning["value"] == "typo_value"


def test_missing_row_returns_default() -> None:
    result = get_llm_provider(_db_no_row())
    assert result == "anthropic_api"


# ── DB failure paths ──────────────────────────────────────────────────────────


def test_db_failure_with_stale_cache_returns_stale_value() -> None:
    get_llm_provider(_db_with_value("bedrock"))
    rc._cached_at = time.monotonic() - CACHE_TTL_SECONDS - 1

    with structlog.testing.capture_logs() as logs:
        result = get_llm_provider(_db_error())

    assert result == "bedrock"
    assert any("db_error" in e.get("event", "") for e in logs)


def test_db_failure_with_no_cache_returns_default() -> None:
    with structlog.testing.capture_logs() as logs:
        result = get_llm_provider(_db_error())

    assert result == "anthropic_api"
    assert any("db_error" in e.get("event", "") for e in logs)


def test_db_failure_logs_the_exception_message() -> None:
    with structlog.testing.capture_logs() as logs:
        get_llm_provider(_db_error())

    warning = next(e for e in logs if "db_error" in e.get("event", ""))
    assert "connection refused" in warning["error"]
