"""Unit tests for the request_lifecycle state machine."""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.core.exceptions import InvalidStateError
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.services.request_lifecycle import VALID_TRANSITIONS, transition


def _make_request(status: str = "PENDING") -> SecretRequest:
    req = SecretRequest(
        service_id=uuid.uuid4(),
        logical_name="db-password",
        environment="dev",
        status=status,
    )
    req.id = uuid.uuid4()
    return req


def _make_db() -> MagicMock:
    return MagicMock()


# ── valid transitions ──────────────────────────────────────────────────────────


def test_pending_to_approved_succeeds() -> None:
    db = _make_db()
    req = _make_request("PENDING")
    event = transition(db, req, "APPROVED", actor="approver@co.com")

    assert req.status == "APPROVED"
    assert isinstance(event, RequestEvent)
    assert event.status == "APPROVED"
    assert event.actor == "approver@co.com"
    assert event.secret_request_id == req.id
    db.add.assert_called_once_with(event)
    db.flush.assert_called_once()


def test_approved_to_provisioning_succeeds() -> None:
    db = _make_db()
    req = _make_request("APPROVED")
    event = transition(db, req, "PROVISIONING", actor="system")

    assert req.status == "PROVISIONING"
    assert event.status == "PROVISIONING"


def test_provisioning_to_provisioned_succeeds() -> None:
    db = _make_db()
    req = _make_request("PROVISIONING")
    event = transition(db, req, "PROVISIONED", actor="system", detail="arn:aws:sm:us-east-1:123:secret:x")

    assert req.status == "PROVISIONED"
    assert event.detail == "arn:aws:sm:us-east-1:123:secret:x"


def test_provisioning_to_failed_succeeds() -> None:
    db = _make_db()
    req = _make_request("PROVISIONING")
    event = transition(db, req, "FAILED", actor="system", detail="AccessDenied from AWS")

    assert req.status == "FAILED"
    assert event.detail == "AccessDenied from AWS"


def test_detail_is_none_when_not_provided() -> None:
    db = _make_db()
    req = _make_request("PENDING")
    event = transition(db, req, "APPROVED", actor="ops@co.com")

    assert event.detail is None


# ── invalid transitions ────────────────────────────────────────────────────────


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
def test_invalid_transition_raises(from_status: str, to_status: str) -> None:
    db = _make_db()
    req = _make_request(from_status)
    with pytest.raises(InvalidStateError) as exc_info:
        transition(db, req, to_status, actor="actor@co.com")

    assert exc_info.value.status_code == 409
    assert from_status in exc_info.value.message
    assert to_status in exc_info.value.message
    db.add.assert_not_called()
    db.flush.assert_not_called()


def test_terminal_provisioned_cannot_transition() -> None:
    db = _make_db()
    req = _make_request("PROVISIONED")
    with pytest.raises(InvalidStateError):
        transition(db, req, "PENDING", actor="actor@co.com")
    assert req.status == "PROVISIONED"  # status unchanged on failure


def test_terminal_failed_cannot_transition() -> None:
    db = _make_db()
    req = _make_request("FAILED")
    with pytest.raises(InvalidStateError):
        transition(db, req, "APPROVED", actor="actor@co.com")
    assert req.status == "FAILED"


# ── VALID_TRANSITIONS map sanity checks ───────────────────────────────────────


def test_all_statuses_have_transition_entries() -> None:
    from app.src.models.secret_request import VALID_STATUSES
    assert set(VALID_TRANSITIONS.keys()) == set(VALID_STATUSES)


def test_all_target_statuses_are_valid() -> None:
    from app.src.models.secret_request import VALID_STATUSES
    valid = set(VALID_STATUSES)
    for targets in VALID_TRANSITIONS.values():
        assert targets.issubset(valid)
