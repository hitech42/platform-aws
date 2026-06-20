"""Unit tests for app.src.services.llm_provider.

No real boto3 or Anthropic SDK calls are made — all I/O is mocked via
unittest.mock.  Tests are grouped by class / function under test.
"""

from unittest.mock import MagicMock, patch

import anthropic
import pytest
import structlog.testing
from botocore.exceptions import ClientError

from app.src.core.exceptions import NarrativeError
from app.src.services.llm_provider import (
    AnthropicAPINarrativeProvider,
    BedrockNarrativeProvider,
    get_active_provider,
)

# ── helpers ───────────────────────────────────────────────────────────────────


def _bedrock_response(text: str) -> dict:  # type: ignore[type-arg]
    return {"output": {"message": {"content": [{"text": text}]}}}


def _anthropic_response(text: str) -> MagicMock:
    block = MagicMock()
    block.text = text
    response = MagicMock()
    response.content = [block]
    return response


def _client_error(code: str, message: str) -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": message}}, "Converse")


# ── BedrockNarrativeProvider ─────────────────────────────────────────────────


def test_bedrock_returns_narrative_on_success(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.llm_provider.settings.aws_endpoint_url", None)
    provider = BedrockNarrativeProvider()
    mock_client = MagicMock()
    mock_client.converse.return_value = _bedrock_response("  narrative text  ")

    with patch.object(provider, "_get_client", return_value=mock_client):
        result = provider.generate_narrative("prompt")

    assert result == "narrative text"


def test_bedrock_raises_narrative_error_on_client_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.llm_provider.settings.aws_endpoint_url", None)
    provider = BedrockNarrativeProvider()
    mock_client = MagicMock()
    mock_client.converse.side_effect = _client_error("ThrottlingException", "Too many tokens")

    with patch.object(provider, "_get_client", return_value=mock_client):
        with pytest.raises(NarrativeError, match="ThrottlingException"):
            provider.generate_narrative("prompt")


def test_bedrock_raises_narrative_error_on_unexpected_exception(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("app.src.services.llm_provider.settings.aws_endpoint_url", None)
    provider = BedrockNarrativeProvider()
    mock_client = MagicMock()
    mock_client.converse.side_effect = RuntimeError("network failure")

    with patch.object(provider, "_get_client", return_value=mock_client):
        with pytest.raises(NarrativeError, match="RuntimeError"):
            provider.generate_narrative("prompt")


def test_bedrock_returns_stub_when_localstack(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.src.services.llm_provider.settings.aws_endpoint_url", "http://localhost:4566"
    )
    provider = BedrockNarrativeProvider()

    with structlog.testing.capture_logs():
        result = provider.generate_narrative("prompt")

    assert "[stub]" in result


def test_bedrock_logs_warning_on_client_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.llm_provider.settings.aws_endpoint_url", None)
    provider = BedrockNarrativeProvider()
    mock_client = MagicMock()
    mock_client.converse.side_effect = _client_error("AccessDeniedException", "model not enabled")

    with patch.object(provider, "_get_client", return_value=mock_client):
        with structlog.testing.capture_logs() as logs:
            with pytest.raises(NarrativeError):
                provider.generate_narrative("prompt")

    assert any("bedrock.error" in e.get("event", "") for e in logs)


def test_bedrock_logs_warning_on_unexpected_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.llm_provider.settings.aws_endpoint_url", None)
    provider = BedrockNarrativeProvider()
    mock_client = MagicMock()
    mock_client.converse.side_effect = ValueError("unexpected")

    with patch.object(provider, "_get_client", return_value=mock_client):
        with structlog.testing.capture_logs() as logs:
            with pytest.raises(NarrativeError):
                provider.generate_narrative("prompt")

    assert any("bedrock.error" in e.get("event", "") for e in logs)


# ── AnthropicAPINarrativeProvider ────────────────────────────────────────────


def test_anthropic_returns_narrative_on_success() -> None:
    provider = AnthropicAPINarrativeProvider("fake-key")
    provider._client = MagicMock()
    provider._client.messages.create.return_value = _anthropic_response("  generated text  ")

    result = provider.generate_narrative("prompt")

    assert result == "generated text"


def test_anthropic_raises_narrative_error_on_api_error() -> None:
    provider = AnthropicAPINarrativeProvider("fake-key")
    provider._client = MagicMock()
    provider._client.messages.create.side_effect = anthropic.APIConnectionError(request=MagicMock())

    with pytest.raises(NarrativeError):
        provider.generate_narrative("prompt")


def test_anthropic_raises_narrative_error_on_unexpected_exception() -> None:
    provider = AnthropicAPINarrativeProvider("fake-key")
    provider._client = MagicMock()
    provider._client.messages.create.side_effect = RuntimeError("connection refused")

    with pytest.raises(NarrativeError, match="RuntimeError"):
        provider.generate_narrative("prompt")


def test_anthropic_logs_warning_on_api_error() -> None:
    provider = AnthropicAPINarrativeProvider("fake-key")
    provider._client = MagicMock()
    provider._client.messages.create.side_effect = anthropic.APIConnectionError(request=MagicMock())

    with structlog.testing.capture_logs() as logs:
        with pytest.raises(NarrativeError):
            provider.generate_narrative("prompt")

    assert any("anthropic.error" in e.get("event", "") for e in logs)


def test_anthropic_logs_warning_on_unexpected_exception() -> None:
    provider = AnthropicAPINarrativeProvider("fake-key")
    provider._client = MagicMock()
    provider._client.messages.create.side_effect = OSError("socket error")

    with structlog.testing.capture_logs() as logs:
        with pytest.raises(NarrativeError):
            provider.generate_narrative("prompt")

    assert any("anthropic.error" in e.get("event", "") for e in logs)


def test_anthropic_client_is_created_lazily() -> None:
    provider = AnthropicAPINarrativeProvider(None)
    assert provider._client is None


# ── get_active_provider ──────────────────────────────────────────────────────


def test_get_active_provider_returns_bedrock(monkeypatch: pytest.MonkeyPatch) -> None:
    mock_config = MagicMock()
    mock_config.get.return_value = "bedrock"
    monkeypatch.setattr("app.src.services.llm_provider.llm_provider_config", mock_config)
    provider = get_active_provider(MagicMock())
    assert isinstance(provider, BedrockNarrativeProvider)


def test_get_active_provider_returns_anthropic(monkeypatch: pytest.MonkeyPatch) -> None:
    mock_config = MagicMock()
    mock_config.get.return_value = "anthropic_api"
    monkeypatch.setattr("app.src.services.llm_provider.llm_provider_config", mock_config)
    provider = get_active_provider(MagicMock())
    assert isinstance(provider, AnthropicAPINarrativeProvider)
