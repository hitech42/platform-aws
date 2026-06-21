"""Unit tests for LLMProviderConfig.

All tests use a mock Session — no DB, no I/O.
The singleton's cache is reset before and after each test via the autouse
fixture so tests are fully independent regardless of execution order.
"""

import time
from collections.abc import Generator
from unittest.mock import MagicMock

import pytest
import structlog.testing

from app.src.core.runtime_config.llm_provider_config import CACHE_TTL_SECONDS, llm_provider_config


@pytest.fixture(autouse=True)
def reset_cache() -> Generator[None, None, None]:
    llm_provider_config._reset_cache()
    yield
    llm_provider_config._reset_cache()


# ── helpers ───────────────────────────────────────────────────────────────────


def _repo_with_value(value: str) -> MagicMock:
    repo = MagicMock()
    repo.get_value.return_value = value
    return repo


def _repo_no_row() -> MagicMock:
    repo = MagicMock()
    repo.get_value.return_value = None
    return repo


def _repo_error() -> MagicMock:
    repo = MagicMock()
    repo.get_value.side_effect = RuntimeError("connection refused")
    return repo


# ── cache behaviour ───────────────────────────────────────────────────────────


def test_cache_miss_queries_db() -> None:
    repo = _repo_with_value("bedrock")
    result = llm_provider_config.get(repo)
    assert result == "bedrock"
    repo.get_value.assert_called_once()


def test_cache_hit_within_ttl_does_not_query_db() -> None:
    repo = _repo_with_value("bedrock")
    llm_provider_config.get(repo)
    repo.get_value.reset_mock()

    llm_provider_config.get(repo)

    repo.get_value.assert_not_called()


def test_cache_hit_returns_previously_fetched_value() -> None:
    llm_provider_config.get(_repo_with_value("bedrock"))
    # Second call uses a different repo mock; if cache is working, this mock is never hit
    result = llm_provider_config.get(_repo_with_value("anthropic_api"))
    assert result == "bedrock"


def test_expired_cache_re_queries_db() -> None:
    repo = _repo_with_value("bedrock")
    llm_provider_config.get(repo)
    repo.get_value.reset_mock()

    llm_provider_config._cached_at = time.monotonic() - CACHE_TTL_SECONDS - 1

    llm_provider_config.get(repo)

    repo.get_value.assert_called_once()


# ── validation ────────────────────────────────────────────────────────────────


def test_valid_bedrock_returned() -> None:
    assert llm_provider_config.get(_repo_with_value("bedrock")) == "bedrock"


def test_valid_anthropic_api_returned() -> None:
    assert llm_provider_config.get(_repo_with_value("anthropic_api")) == "anthropic_api"


def test_invalid_db_value_falls_back_to_default() -> None:
    with structlog.testing.capture_logs() as logs:
        result = llm_provider_config.get(_repo_with_value("openai"))

    assert result == "anthropic_api"
    assert any(
        e.get("log_level") == "warning" and "invalid_value" in e.get("event", "") for e in logs
    )


def test_invalid_db_value_logs_the_bad_value() -> None:
    with structlog.testing.capture_logs() as logs:
        llm_provider_config.get(_repo_with_value("typo_value"))

    warning = next(e for e in logs if "invalid_value" in e.get("event", ""))
    assert warning["value"] == "typo_value"


def test_missing_row_returns_default() -> None:
    result = llm_provider_config.get(_repo_no_row())
    assert result == "anthropic_api"


# ── DB failure paths ──────────────────────────────────────────────────────────


def test_db_failure_with_stale_cache_returns_stale_value() -> None:
    llm_provider_config.get(_repo_with_value("bedrock"))
    llm_provider_config._cached_at = time.monotonic() - CACHE_TTL_SECONDS - 1

    with structlog.testing.capture_logs() as logs:
        result = llm_provider_config.get(_repo_error())

    assert result == "bedrock"
    assert any("db_error" in e.get("event", "") for e in logs)


def test_db_failure_with_no_cache_returns_default() -> None:
    with structlog.testing.capture_logs() as logs:
        result = llm_provider_config.get(_repo_error())

    assert result == "anthropic_api"
    assert any("db_error" in e.get("event", "") for e in logs)


def test_db_failure_logs_the_exception_message() -> None:
    with structlog.testing.capture_logs() as logs:
        llm_provider_config.get(_repo_error())

    warning = next(e for e in logs if "db_error" in e.get("event", ""))
    assert "connection refused" in warning["error"]
