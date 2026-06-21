"""Unit tests for SecretRequestRepository — DB is fully mocked."""

import uuid
from unittest.mock import MagicMock

from app.src.models.secret_request import SecretRequest
from app.src.repositories.secret_request_repository import SecretRequestRepository


def _repo() -> tuple[SecretRequestRepository, MagicMock]:
    db = MagicMock()
    return SecretRequestRepository(db), db


def _make_request(status: str = "PENDING") -> SecretRequest:
    req = SecretRequest(
        service_id=uuid.uuid4(),
        logical_name="db-password",
        environment="dev",
        status=status,
    )
    req.id = uuid.uuid4()
    return req


# ── create ─────────────────────────────────────────────────────────────────────


def test_create_adds_and_flushes() -> None:
    repo, db = _repo()
    svc_id = uuid.uuid4()
    result = repo.create(
        service_id=svc_id,
        logical_name="api-key",
        environment="dev",
        description="desc",
    )

    db.add.assert_called_once()
    db.flush.assert_called_once()
    assert result.service_id == svc_id
    assert result.logical_name == "api-key"
    assert result.status == "PENDING"


def test_create_uses_provided_status() -> None:
    repo, db = _repo()
    result = repo.create(
        service_id=uuid.uuid4(),
        logical_name="key",
        environment="prod",
        description=None,
        status="PROVISIONING",
    )
    assert result.status == "PROVISIONING"


# ── get_by_id ──────────────────────────────────────────────────────────────────


def test_get_by_id_returns_request_when_found() -> None:
    req = _make_request()
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = req

    assert repo.get_by_id(req.id) is req


def test_get_by_id_returns_none_when_missing() -> None:
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = None

    assert repo.get_by_id(uuid.uuid4()) is None


# ── get_for_update ─────────────────────────────────────────────────────────────


def test_get_for_update_returns_request_when_found() -> None:
    req = _make_request()
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = req

    assert repo.get_for_update(req.id) is req


def test_get_for_update_returns_none_when_missing() -> None:
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = None

    assert repo.get_for_update(uuid.uuid4()) is None


# ── exists_for_tuple ───────────────────────────────────────────────────────────


def test_exists_for_tuple_true_when_row_found() -> None:
    req = _make_request()
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = req

    assert repo.exists_for_tuple(req.service_id, "db-password", "dev") is True


def test_exists_for_tuple_false_when_no_row() -> None:
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = None

    assert repo.exists_for_tuple(uuid.uuid4(), "api-key", "staging") is False


# ── set_secret_arn ─────────────────────────────────────────────────────────────


def test_set_secret_arn_updates_request_and_flushes() -> None:
    req = _make_request()
    repo, db = _repo()
    arn = "arn:aws:secretsmanager:us-east-1:123:secret:platform/svc/dev/db-pass"

    result = repo.set_secret_arn(req, arn)

    assert req.secret_arn == arn
    assert result is req
    db.flush.assert_called_once()
