"""Unit tests for NarrativeService — repos and LLM provider are fully mocked."""

import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import pytest

from app.src.core.exceptions import NarrativeError, NotFoundError
from app.src.repositories.config_repository import ConfigRepository
from app.src.repositories.request_event_repository import RequestEventRepository
from app.src.repositories.secret_request_repository import SecretRequestRepository
from app.src.repositories.service_repository import ServiceRepository
from app.src.services.narrative_service import NarrativeService

_SVC_MODULE = "app.src.services.narrative_service"


# ── helpers ────────────────────────────────────────────────────────────────────


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
    r.id = uuid.uuid4()
    r.service_id = uuid.uuid4()
    r.logical_name = logical_name
    r.environment = environment
    r.status = status
    return r


def _make_service_model(name: str = "payments-api", team: str = "payments") -> MagicMock:
    s = MagicMock()
    s.name = name
    s.team = team
    s.owner_email = "alice@example.com"
    return s


def _clean_risk_flags(
    ownership_mismatch: bool = False,
    naming_violations: list[str] | None = None,
    is_production: bool = False,
) -> dict:  # type: ignore[type-arg]
    nv: list[str] = naming_violations or []
    return {
        "ownership_mismatch": ownership_mismatch,
        "naming_violations": nv,
        "is_production": is_production,
        "has_any_flag": ownership_mismatch or bool(nv) or is_production,
    }


def _make_narrative_svc() -> tuple[NarrativeService, MagicMock, MagicMock, MagicMock, MagicMock]:
    secret_request_repo = MagicMock(spec=SecretRequestRepository)
    request_event_repo = MagicMock(spec=RequestEventRepository)
    service_repo = MagicMock(spec=ServiceRepository)
    config_repo = MagicMock(spec=ConfigRepository)
    svc = NarrativeService(
        secret_request_repo=secret_request_repo,
        request_event_repo=request_event_repo,
        service_repo=service_repo,
        config_repo=config_repo,
    )
    return svc, secret_request_repo, request_event_repo, service_repo, config_repo


# ── _build_prompt ─────────────────────────────────────────────────────────────


def test_prompt_contains_service_name() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = NarrativeService._build_prompt(
        events, _clean_risk_flags(), _make_request(), _make_service_model()
    )
    assert "payments-api" in prompt


def test_prompt_contains_logical_name_and_environment() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = NarrativeService._build_prompt(
        events, _clean_risk_flags(), _make_request("stripe-key", "prod"), _make_service_model()
    )
    assert "stripe-key" in prompt
    assert "prod" in prompt


def test_prompt_contains_ownership_mismatch_flag() -> None:
    events = [_make_event("PENDING", "bob@example.com")]
    prompt = NarrativeService._build_prompt(
        events, _clean_risk_flags(ownership_mismatch=True), _make_request(), _make_service_model()
    )
    assert "Ownership mismatch" in prompt


def test_prompt_contains_naming_violation() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    flags = _clean_risk_flags(naming_violations=["name must be lowercase, hyphen-separated"])
    prompt = NarrativeService._build_prompt(events, flags, _make_request(), _make_service_model())
    assert "lowercase" in prompt


def test_prompt_contains_production_flag() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    flags = _clean_risk_flags(is_production=True)
    prompt = NarrativeService._build_prompt(
        events, flags, _make_request(environment="prod"), _make_service_model()
    )
    assert "Production environment" in prompt


def test_prompt_no_active_flags_shows_none() -> None:
    events = [_make_event("PENDING", "alice@example.com")]
    prompt = NarrativeService._build_prompt(
        events, _clean_risk_flags(), _make_request(), _make_service_model()
    )
    assert "None: all checks passed" in prompt


def test_prompt_contains_timeline_entries() -> None:
    events = [
        _make_event("PENDING", "alice@example.com"),
        _make_event("APPROVED", "bob@example.com"),
    ]
    prompt = NarrativeService._build_prompt(
        events, _clean_risk_flags(), _make_request(), _make_service_model()
    )
    assert "PENDING" in prompt
    assert "APPROVED" in prompt
    assert "alice@example.com" in prompt


# ── generate_summary ──────────────────────────────────────────────────────────


def test_generate_summary_raises_not_found_when_request_missing() -> None:
    svc, req_repo, _, _, _ = _make_narrative_svc()
    req_repo.get_by_id.return_value = None

    with pytest.raises(NotFoundError) as exc_info:
        svc.generate_summary(uuid.uuid4())

    assert exc_info.value.field == "request_id"


def test_generate_summary_returns_facts_and_narrative() -> None:
    svc, req_repo, event_repo, service_repo, _ = _make_narrative_svc()
    req = _make_request(environment="dev")
    service = _make_service_model()
    service.owner_email = "alice@co.com"
    events = [_make_event("PENDING", "alice@co.com")]

    req_repo.get_by_id.return_value = req
    service_repo.get_by_id.return_value = service
    event_repo.list_for_request.return_value = events

    mock_provider = MagicMock()
    mock_provider.generate_narrative.return_value = "All good."

    with patch(f"{_SVC_MODULE}.get_active_provider", return_value=mock_provider):
        result = svc.generate_summary(req.id)

    assert result.narrative == "All good."
    assert result.facts.ownership_mismatch is False


def test_generate_summary_sets_narrative_null_on_provider_error() -> None:
    svc, req_repo, event_repo, service_repo, _ = _make_narrative_svc()
    req = _make_request()
    service = _make_service_model()
    service.owner_email = "owner@co.com"

    req_repo.get_by_id.return_value = req
    service_repo.get_by_id.return_value = service
    event_repo.list_for_request.return_value = [_make_event("PENDING", "owner@co.com")]

    failing_provider = MagicMock()
    failing_provider.generate_narrative.side_effect = NarrativeError("Bedrock unavailable")

    with patch(f"{_SVC_MODULE}.get_active_provider", return_value=failing_provider):
        result = svc.generate_summary(req.id)

    assert result.narrative is None
    assert result.narrative_generated_by is None
    assert "Bedrock unavailable" in (result.narrative_error or "")
    assert result.facts is not None
