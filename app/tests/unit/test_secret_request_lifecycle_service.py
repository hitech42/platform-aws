"""Unit tests for SecretRequestLifecycleService — repos, DB, and AWS are mocked."""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.core.exceptions import ConflictError, InvalidStateError, NotFoundError, ValidationError
from app.src.models.secret_request import VALID_STATUSES, SecretRequest
from app.src.repositories.request_event_repository import RequestEventRepository
from app.src.repositories.secret_request_repository import SecretRequestRepository
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.secret_request import SecretRequestBody
from app.src.services.secret_request_lifecycle_service import (
    ApproveResult,
    SecretRequestLifecycleService,
)
from app.src.services.secrets_manager_service import SecretsManager

# ── helpers ────────────────────────────────────────────────────────────────────


def _make_request(status: str = "PENDING") -> SecretRequest:
    req = SecretRequest(
        service_id=uuid.uuid4(),
        logical_name="db-password",
        environment="dev",
        status=status,
    )
    req.id = uuid.uuid4()
    return req


def _make_svc() -> tuple[
    SecretRequestLifecycleService,
    MagicMock,
    MagicMock,
    MagicMock,
    MagicMock,
    MagicMock,
]:
    mock_secrets_manager = MagicMock(spec=SecretsManager)
    secret_request_repo = MagicMock(spec=SecretRequestRepository)
    request_event_repo = MagicMock(spec=RequestEventRepository)
    service_repo = MagicMock(spec=ServiceRepository)
    db = MagicMock()
    svc = SecretRequestLifecycleService(
        db=db,
        secrets_manager=mock_secrets_manager,
        secret_request_repo=secret_request_repo,
        request_event_repo=request_event_repo,
        service_repo=service_repo,
    )
    return svc, db, mock_secrets_manager, secret_request_repo, request_event_repo, service_repo


# ── _VALID_TRANSITIONS map completeness ───────────────────────────────────────


def test_all_statuses_have_transition_entries() -> None:
    assert set(SecretRequestLifecycleService._VALID_TRANSITIONS.keys()) == set(VALID_STATUSES)


def test_all_target_statuses_are_valid() -> None:
    valid = set(VALID_STATUSES)
    for targets in SecretRequestLifecycleService._VALID_TRANSITIONS.values():
        assert targets.issubset(valid)


# ── _transition: valid paths ───────────────────────────────────────────────────


def test_transition_pending_to_approved() -> None:
    svc, _, _, _, event_repo, _ = _make_svc()
    req = _make_request("PENDING")
    svc._transition(req, "APPROVED", actor="approver@co.com")

    assert req.status == "APPROVED"
    event_repo.create.assert_called_once_with(
        secret_request_id=req.id, status="APPROVED", actor="approver@co.com", detail=None
    )


def test_transition_approved_to_provisioning() -> None:
    svc, _, _, _, event_repo, _ = _make_svc()
    req = _make_request("APPROVED")
    svc._transition(req, "PROVISIONING", actor="system")

    assert req.status == "PROVISIONING"
    event_repo.create.assert_called_once_with(
        secret_request_id=req.id, status="PROVISIONING", actor="system", detail=None
    )


def test_transition_provisioning_to_provisioned_with_detail() -> None:
    svc, _, _, _, event_repo, _ = _make_svc()
    req = _make_request("PROVISIONING")
    arn = "arn:aws:sm:us-east-1:123:secret:x"
    svc._transition(req, "PROVISIONED", actor="system", detail=arn)

    assert req.status == "PROVISIONED"
    event_repo.create.assert_called_once_with(
        secret_request_id=req.id, status="PROVISIONED", actor="system", detail=arn
    )


def test_transition_provisioning_to_failed_with_detail() -> None:
    svc, _, _, _, event_repo, _ = _make_svc()
    req = _make_request("PROVISIONING")
    svc._transition(req, "FAILED", actor="system", detail="AccessDenied")

    assert req.status == "FAILED"
    event_repo.create.assert_called_once_with(
        secret_request_id=req.id, status="FAILED", actor="system", detail="AccessDenied"
    )


# ── _transition: invalid paths ─────────────────────────────────────────────────


@pytest.mark.parametrize(
    "from_status, to_status",
    [
        ("PENDING", "PROVISIONING"),
        ("PENDING", "PROVISIONED"),
        ("PENDING", "FAILED"),
        ("APPROVED", "APPROVED"),
        ("APPROVED", "PROVISIONED"),
        ("APPROVED", "FAILED"),
        ("PROVISIONED", "APPROVED"),
        ("PROVISIONED", "FAILED"),
        ("FAILED", "PENDING"),
        ("FAILED", "PROVISIONED"),
    ],
)
def test_invalid_transition_raises_and_does_not_mutate(from_status: str, to_status: str) -> None:
    svc, _, _, _, event_repo, _ = _make_svc()
    req = _make_request(from_status)

    with pytest.raises(InvalidStateError) as exc_info:
        svc._transition(req, to_status, actor="actor@co.com")

    assert exc_info.value.status_code == 409
    assert from_status in exc_info.value.message
    assert to_status in exc_info.value.message
    assert req.status == from_status  # unchanged
    event_repo.create.assert_not_called()


def test_terminal_provisioned_cannot_transition() -> None:
    svc, _, _, _, _, _ = _make_svc()
    req = _make_request("PROVISIONED")
    with pytest.raises(InvalidStateError):
        svc._transition(req, "PENDING", actor="actor@co.com")
    assert req.status == "PROVISIONED"


def test_terminal_failed_cannot_transition() -> None:
    svc, _, _, _, _, _ = _make_svc()
    req = _make_request("FAILED")
    with pytest.raises(InvalidStateError):
        svc._transition(req, "APPROVED", actor="actor@co.com")
    assert req.status == "FAILED"


# ── create_request ─────────────────────────────────────────────────────────────


def test_create_request_commits_and_returns_request() -> None:
    svc, db, _, req_repo, event_repo, service_repo = _make_svc()
    service_repo.get_by_id.return_value = MagicMock()
    req_repo.exists_for_tuple.return_value = False
    created_req = _make_request()
    req_repo.create.return_value = created_req

    body = SecretRequestBody(
        logical_name="api-key", environment="dev", generate_value=True, requested_by="alice@co.com"
    )
    result = svc.create_request(created_req.service_id, body)

    db.commit.assert_called_once()
    db.refresh.assert_called_once_with(created_req)
    event_repo.create.assert_called_once_with(
        secret_request_id=created_req.id, status="PENDING", actor="alice@co.com", detail=None
    )
    assert result is created_req


def test_create_request_uses_api_actor_when_no_requested_by() -> None:
    svc, db, _, req_repo, event_repo, service_repo = _make_svc()
    service_repo.get_by_id.return_value = MagicMock()
    req_repo.exists_for_tuple.return_value = False
    created_req = _make_request()
    req_repo.create.return_value = created_req

    body = SecretRequestBody(logical_name="key", environment="dev", generate_value=True)
    svc.create_request(created_req.service_id, body)

    event_repo.create.assert_called_once_with(
        secret_request_id=created_req.id, status="PENDING", actor="api", detail=None
    )


def test_create_request_raises_not_found_when_service_missing() -> None:
    svc, _, _, _, _, service_repo = _make_svc()
    service_repo.get_by_id.return_value = None

    body = SecretRequestBody(logical_name="key", environment="dev", generate_value=True)
    with pytest.raises(NotFoundError) as exc_info:
        svc.create_request(uuid.uuid4(), body)

    assert exc_info.value.field == "service_id"


def test_create_request_raises_validation_error_when_generate_value_false() -> None:
    svc, _, _, _, _, service_repo = _make_svc()
    service_repo.get_by_id.return_value = MagicMock()

    body = SecretRequestBody(logical_name="key", environment="dev", generate_value=False)
    with pytest.raises(ValidationError) as exc_info:
        svc.create_request(uuid.uuid4(), body)

    assert exc_info.value.field == "generate_value"


def test_create_request_raises_conflict_when_tuple_exists() -> None:
    svc, _, _, req_repo, _, service_repo = _make_svc()
    service_repo.get_by_id.return_value = MagicMock()
    req_repo.exists_for_tuple.return_value = True

    body = SecretRequestBody(logical_name="db-pass", environment="dev", generate_value=True)
    with pytest.raises(ConflictError) as exc_info:
        svc.create_request(uuid.uuid4(), body)

    assert exc_info.value.field == "logical_name"


# ── get_request ────────────────────────────────────────────────────────────────


def test_get_request_returns_request() -> None:
    req = _make_request()
    svc, _, _, req_repo, _, _ = _make_svc()
    req_repo.get_by_id.return_value = req

    assert svc.get_request(req.id) is req


def test_get_request_raises_not_found() -> None:
    svc, _, _, req_repo, _, _ = _make_svc()
    req_repo.get_by_id.return_value = None

    with pytest.raises(NotFoundError) as exc_info:
        svc.get_request(uuid.uuid4())

    assert exc_info.value.field == "request_id"


# ── get_events ─────────────────────────────────────────────────────────────────


def test_get_events_returns_event_list() -> None:
    req = _make_request()
    svc, _, _, req_repo, event_repo, _ = _make_svc()
    req_repo.get_by_id.return_value = req
    events = [MagicMock(), MagicMock()]
    event_repo.list_for_request.return_value = events

    assert svc.get_events(req.id) == events


def test_get_events_raises_not_found_when_request_missing() -> None:
    svc, _, _, req_repo, _, _ = _make_svc()
    req_repo.get_by_id.return_value = None

    with pytest.raises(NotFoundError):
        svc.get_events(uuid.uuid4())


# ── approve_request ────────────────────────────────────────────────────────────


def test_approve_request_provisioned_commits_twice_and_returns_result() -> None:
    svc, db, mock_sm, req_repo, _, service_repo = _make_svc()
    req = _make_request("PENDING")
    req_repo.get_for_update.return_value = req
    mock_service = MagicMock()
    mock_service.name = "my-svc"
    service_repo.get_by_id.return_value = mock_service
    fake_arn = "arn:aws:secretsmanager:us-east-1:123:secret:platform/my-svc/dev/db-pass"
    mock_sm.create_app_secret.return_value = fake_arn

    result = svc.approve_request(req.id, approver_email="ops@co.com")

    assert isinstance(result, ApproveResult)
    assert result.from_status == "PENDING"
    assert result.request is req
    assert result.request.status == "PROVISIONED"
    assert db.commit.call_count == 2


def test_approve_request_not_found_raises() -> None:
    svc, _, _, req_repo, _, _ = _make_svc()
    req_repo.get_for_update.return_value = None

    with pytest.raises(NotFoundError) as exc_info:
        svc.approve_request(uuid.uuid4(), approver_email="ops@co.com")

    assert exc_info.value.field == "request_id"


def test_approve_request_aws_failure_records_failed_status() -> None:
    svc, db, mock_sm, req_repo, _, service_repo = _make_svc()
    req = _make_request("PENDING")
    req_repo.get_for_update.return_value = req
    mock_service = MagicMock()
    mock_service.name = "my-svc"
    service_repo.get_by_id.return_value = mock_service
    mock_sm.create_app_secret.side_effect = RuntimeError("connection refused")

    result = svc.approve_request(req.id, approver_email="ops@co.com")

    assert result.request.status == "FAILED"
    assert db.commit.call_count == 2
