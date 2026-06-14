"""Integration tests for the data layer.

Uses testcontainers (see conftest.py) — requires Docker. Does NOT touch the
developer's locally-running Postgres.
"""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.src.db.session import get_db
from app.src.main import app
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.models.service import Service


# ── helpers ────────────────────────────────────────────────────────────────────


def make_service(session: Session, **kwargs: str) -> Service:
    defaults: dict[str, str] = {
        "name": f"svc-{uuid.uuid4().hex[:8]}",
        "team": "platform",
        "owner_email": "ops@co.com",
    }
    defaults.update(kwargs)
    svc = Service(**defaults)  # type: ignore[arg-type]
    session.add(svc)
    session.flush()
    return svc


def make_secret_request(session: Session, service: Service, **kwargs: str) -> SecretRequest:
    defaults: dict = {
        "service_id": service.id,
        "logical_name": f"secret-{uuid.uuid4().hex[:6]}",
        "environment": "dev",
    }
    defaults.update(kwargs)
    req = SecretRequest(**defaults)
    session.add(req)
    session.flush()
    return req


# ── service table ──────────────────────────────────────────────────────────────


def test_insert_service_generates_uuid(db_session: Session) -> None:
    svc = make_service(db_session)
    assert isinstance(svc.id, uuid.UUID)
    assert svc.created_at is not None


def test_service_name_unique_constraint(db_session: Session) -> None:
    name = f"svc-{uuid.uuid4().hex[:8]}"
    make_service(db_session, name=name)
    with pytest.raises(IntegrityError):
        make_service(db_session, name=name)


# ── secret_requests table ──────────────────────────────────────────────────────


def test_insert_secret_request_defaults(db_session: Session) -> None:
    svc = make_service(db_session)
    req = make_secret_request(db_session, svc)
    assert isinstance(req.id, uuid.UUID)
    assert req.status == "PENDING"
    assert req.created_at is not None
    assert req.updated_at is not None


def test_unique_constraint_service_logical_env(db_session: Session) -> None:
    """The same (service_id, logical_name, environment) combination must be rejected."""
    svc = make_service(db_session)
    make_secret_request(
        db_session, svc, logical_name="db-password", environment="prod"
    )
    with pytest.raises(IntegrityError):
        make_secret_request(
            db_session, svc, logical_name="db-password", environment="prod"
        )


def test_same_logical_name_different_env_allowed(db_session: Session) -> None:
    svc = make_service(db_session)
    make_secret_request(db_session, svc, logical_name="api-key", environment="dev")
    make_secret_request(db_session, svc, logical_name="api-key", environment="prod")
    # No error — unique constraint allows same name across different environments.


# ── request_events table ───────────────────────────────────────────────────────


def test_insert_request_event(db_session: Session) -> None:
    svc = make_service(db_session)
    req = make_secret_request(db_session, svc)
    ev = RequestEvent(
        secret_request_id=req.id,
        status="APPROVED",
        actor="approver@co.com",
        detail="Approved in code review",
    )
    db_session.add(ev)
    db_session.flush()
    assert isinstance(ev.id, uuid.UUID)
    assert ev.timestamp is not None


def test_request_event_fk_nonexistent_secret_request(db_session: Session) -> None:
    """Inserting an event for a non-existent secret_request_id must raise IntegrityError."""
    ev = RequestEvent(
        secret_request_id=uuid.uuid4(),  # no matching row
        status="PENDING",
        actor="system",
    )
    db_session.add(ev)
    with pytest.raises(IntegrityError):
        db_session.flush()


# ── /readyz health check ───────────────────────────────────────────────────────


def test_readyz_returns_200_when_db_reachable(db_engine: object) -> None:
    """Override the app's get_db dependency to use the testcontainers engine."""
    from sqlalchemy import Engine
    from sqlalchemy.orm import sessionmaker

    assert isinstance(db_engine, Engine)
    TestSession = sessionmaker(bind=db_engine)

    def override_get_db() -> Session:  # type: ignore[misc]
        db = TestSession()
        try:
            yield db  # type: ignore[misc]
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        client = TestClient(app)
        response = client.get("/readyz")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert data["db"] == "ok"
    finally:
        app.dependency_overrides.clear()
