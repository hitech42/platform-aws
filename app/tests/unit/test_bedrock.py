"""Unit tests for the Bedrock narrative wrapper.

boto3 bedrock-runtime client is fully mocked throughout.
"""

from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import pytest
from botocore.exceptions import ClientError

from app.src.services.bedrock import (
    BEDROCK_MODEL_ID,
    build_prompt,
    generate_request_narrative,
)

# ── helpers ───────────────────────────────────────────────────────────────────


def _make_event(status: str, actor: str, detail: str | None = None) -> MagicMock:
    e = MagicMock()
    e.status = status
    e.actor = actor
    e.detail = detail
    e.timestamp = datetime(2026, 6, 19, 10, 0, 0, tzinfo=UTC)
    return e


def _make_request(
    logical_name: str = "db-password",
    environment: str = "dev",
    status: str = "PROVISIONED",
) -> MagicMock:
    r = MagicMock()
    r.logical_name = logical_name
    r.environment = environment
    r.status = status
    return r


def _make_service(name: str = "payments-api", team: str = "payments") -> MagicMock:
    s = MagicMock()
    s.name = name
    s.team = team
    s.owner_email = "alice@example.com"
    return s


def _clean_risk_flags(
    ownership_mismatch: bool = False,
    naming_violations: list[str] | None = None,
    is_production: bool = False,
) -> dict:
    nv: list[str] = naming_violations or []
    return {
        "ownership_mismatch": ownership_mismatch,
        "naming_violations": nv,
        "is_production": is_production,
        "has_any_flag": ownership_mismatch or bool(nv) or is_production,
    }


def _make_converse_response(text: str) -> dict:
    return {"output": {"message": {"content": [{"text": text}]}}}


def _make_client_error(code: str) -> ClientError:
    return ClientError(
        error_response={"Error": {"Code": code, "Message": "mocked error"}},
        operation_name="Converse",
    )


# ── build_prompt ─────────────────────────────────────────────────────────────


def test_prompt_contains_service_name() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = build_prompt(events, _clean_risk_flags(), _make_request(), _make_service())
    assert "payments-api" in prompt


def test_prompt_contains_logical_name_and_environment() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = build_prompt(
        events,
        _clean_risk_flags(),
        _make_request("stripe-key", "prod"),
        _make_service(),
    )
    assert "stripe-key" in prompt
    assert "prod" in prompt


def test_prompt_contains_ownership_mismatch_flag() -> None:
    events = [_make_event("PENDING", "bob@example.com")]
    flags = _clean_risk_flags(ownership_mismatch=True)
    prompt = build_prompt(events, flags, _make_request(), _make_service())
    assert "Ownership mismatch" in prompt


def test_prompt_contains_naming_violation() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    flags = _clean_risk_flags(naming_violations=["name must be lowercase, hyphen-separated"])
    prompt = build_prompt(events, flags, _make_request(), _make_service())
    assert "lowercase" in prompt


def test_prompt_contains_production_flag() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    flags = _clean_risk_flags(is_production=True)
    prompt = build_prompt(events, flags, _make_request(environment="prod"), _make_service())
    assert "Production environment" in prompt


def test_prompt_no_active_flags_shows_none() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = build_prompt(events, _clean_risk_flags(), _make_request(), _make_service())
    assert "None: all checks passed" in prompt


def test_prompt_contains_timeline_entries() -> None:
    events = [
        _make_event("PENDING", "alice@example.com"),
        _make_event("APPROVED", "bob@example.com"),
    ]
    prompt = build_prompt(events, _clean_risk_flags(), _make_request(), _make_service())
    assert "PENDING" in prompt
    assert "APPROVED" in prompt
    assert "alice@example.com" in prompt


# ── LocalStack stub path ──────────────────────────────────────────────────────


def test_stub_returned_when_endpoint_url_set(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.src.services.bedrock.settings.aws_endpoint_url", "http://localhost:4566"
    )

    events = [_make_event("PENDING", "alice@example.com")]
    narrative, error = generate_request_narrative(
        events, _clean_risk_flags(), _make_request(), _make_service()
    )

    assert narrative is not None
    assert "[stub]" in narrative
    assert error is None


def test_stub_does_not_call_boto3(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.src.services.bedrock.settings.aws_endpoint_url", "http://localhost:4566"
    )

    with patch("app.src.services.bedrock.boto3.client") as mock_boto:
        generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )
    mock_boto.assert_not_called()


# ── happy path ────────────────────────────────────────────────────────────────


def test_successful_call_returns_narrative(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    mock_client = MagicMock()
    mock_client.converse.return_value = _make_converse_response("All good.")

    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        narrative, error = generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )

    assert narrative == "All good."
    assert error is None


def test_correct_model_id_used(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    mock_client = MagicMock()
    mock_client.converse.return_value = _make_converse_response("ok")

    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )

    call_kwargs = mock_client.converse.call_args.kwargs
    assert call_kwargs["modelId"] == BEDROCK_MODEL_ID


def test_risk_flags_forwarded_to_prompt(monkeypatch: pytest.MonkeyPatch) -> None:
    """The prompt sent to Bedrock must include the pre-computed flags."""
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    captured_prompts: list[str] = []

    def fake_converse(**kwargs: object) -> dict:
        messages = kwargs.get("messages", [])
        for m in messages:  # type: ignore[union-attr]
            for block in m.get("content", []):
                captured_prompts.append(block.get("text", ""))
        return _make_converse_response("ok")

    mock_client = MagicMock()
    mock_client.converse.side_effect = fake_converse

    flags = _clean_risk_flags(ownership_mismatch=True, is_production=True)
    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            flags,
            _make_request(environment="prod"),
            _make_service(),
        )

    combined = " ".join(captured_prompts)
    assert "Ownership mismatch" in combined
    assert "Production environment" in combined


# ── graceful fallback on errors ───────────────────────────────────────────────


def test_access_denied_returns_error_not_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    mock_client = MagicMock()
    mock_client.converse.side_effect = _make_client_error("AccessDeniedException")

    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        narrative, error = generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )

    assert narrative is None
    assert error is not None
    assert "AccessDeniedException" in error


def test_throttling_returns_error_not_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    mock_client = MagicMock()
    mock_client.converse.side_effect = _make_client_error("ThrottlingException")

    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        narrative, error = generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )

    assert narrative is None
    assert "ThrottlingException" in (error or "")


def test_unexpected_exception_returns_error_not_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.bedrock.settings.aws_endpoint_url", None)

    mock_client = MagicMock()
    mock_client.converse.side_effect = RuntimeError("network timeout")

    with patch("app.src.services.bedrock.boto3.client", return_value=mock_client):
        narrative, error = generate_request_narrative(
            [_make_event("PENDING", "alice@example.com")],
            _clean_risk_flags(),
            _make_request(),
            _make_service(),
        )

    assert narrative is None
    assert error is not None
    assert "RuntimeError" in error
