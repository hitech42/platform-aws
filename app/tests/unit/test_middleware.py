"""Unit tests for RequestLoggingMiddleware."""

import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock

import structlog.testing
from fastapi import APIRouter
from fastapi.testclient import TestClient

from app.src.main import app

# Mount minimal test routes (no DB needed — middleware runs regardless of handler).
_test_router = APIRouter(prefix="/_mw_test", include_in_schema=False)


@_test_router.get("/ok")
def _ok() -> dict:  # type: ignore[type-arg]
    return {"ok": True}


@_test_router.get("/secret-requests/{request_id}/events")
def _events(request_id: uuid.UUID) -> list:  # type: ignore[type-arg]
    return []


app.include_router(_test_router)
client = TestClient(app)

# ── request log is emitted ─────────────────────────────────────────────────────


def test_request_log_emitted_for_normal_endpoint() -> None:
    with structlog.testing.capture_logs() as logs:
        client.get("/_mw_test/ok")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert len(request_logs) == 1
    entry = request_logs[0]
    assert entry["method"] == "GET"
    assert entry["path"] == "/_mw_test/ok"
    assert entry["status_code"] == 200
    assert isinstance(entry["duration_ms"], int)


def test_request_log_includes_status_code_on_404() -> None:
    with structlog.testing.capture_logs() as logs:
        client.get("/_mw_test/nonexistent")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert any(e["status_code"] == 404 for e in request_logs)


# ── secret_request_id extraction ──────────────────────────────────────────────


def test_request_log_extracts_secret_request_id_from_path() -> None:
    fake_id = str(uuid.uuid4())
    with structlog.testing.capture_logs() as logs:
        client.get(f"/_mw_test/secret-requests/{fake_id}/events")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert len(request_logs) == 1
    assert request_logs[0]["secret_request_id"] == fake_id


def test_request_log_has_no_secret_request_id_for_non_secret_path() -> None:
    with structlog.testing.capture_logs() as logs:
        client.get("/_mw_test/ok")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert "secret_request_id" not in request_logs[0]


# ── health endpoints logged at DEBUG ──────────────────────────────────────────


def test_healthz_logged_at_debug_not_info() -> None:
    with structlog.testing.capture_logs() as logs:
        client.get("/healthz")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert len(request_logs) == 1
    assert request_logs[0]["log_level"] == "debug"


def test_readyz_logged_at_debug_not_info() -> None:
    from app.src.db.session import get_db

    with structlog.testing.capture_logs() as logs:
        mock_db = MagicMock()
        app.dependency_overrides[get_db] = lambda: mock_db
        try:
            client.get("/readyz")
        finally:
            app.dependency_overrides.clear()

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert len(request_logs) == 1
    assert request_logs[0]["log_level"] == "debug"


def test_normal_endpoint_logged_at_info() -> None:
    with structlog.testing.capture_logs() as logs:
        client.get("/_mw_test/ok")

    request_logs = [e for e in logs if e.get("event") == "request"]
    assert request_logs[0]["log_level"] == "info"


# ── from_status / to_status via request.state ─────────────────────────────────


def test_from_and_to_status_included_when_set_on_request_state() -> None:
    """Verify the middleware picks up state set by the approve route."""
    from fastapi import Request as FastAPIRequest

    _state_router = APIRouter(prefix="/_mw_state", include_in_schema=False)

    @_state_router.post("/lifecycle")
    def _lifecycle(req: FastAPIRequest) -> dict:  # type: ignore[type-arg]
        req.state.from_status = "PENDING"
        req.state.to_status = "PROVISIONED"
        return {}

    app.include_router(_state_router)
    try:
        with structlog.testing.capture_logs() as logs:
            client.post("/_mw_state/lifecycle")

        request_logs = [e for e in logs if e.get("event") == "request"]
        assert len(request_logs) == 1
        assert request_logs[0]["from_status"] == "PENDING"
        assert request_logs[0]["to_status"] == "PROVISIONED"
    finally:
        # Remove the dynamically added routes to avoid polluting other tests.
        app.router.routes = [
            r for r in app.router.routes if not getattr(r, "path", "").startswith("/_mw_state")
        ]


# ── secret_provisioning_outcome event ─────────────────────────────────────────


def test_provisioning_outcome_provisioned_event_shape() -> None:
    """The CloudWatch metric filter event must have exactly the right shape."""
    from app.src.repositories.request_event_repository import RequestEventRepository
    from app.src.repositories.secret_request_repository import SecretRequestRepository
    from app.src.repositories.service_repository import ServiceRepository
    from app.src.services.dependencies import get_secret_request_lifecycle_service
    from app.src.services.secret_request_lifecycle_service import SecretRequestLifecycleService
    from app.src.services.secrets_manager_service import SecretsManager

    svc_id = uuid.uuid4()
    req_id = uuid.uuid4()

    _now = datetime(2026, 6, 14, tzinfo=UTC)
    mock_req = MagicMock()
    mock_req.id = req_id
    mock_req.service_id = svc_id
    mock_req.status = "PENDING"
    mock_req.logical_name = "db-pass"
    mock_req.environment = "dev"
    mock_req.description = None
    mock_req.secret_arn = None
    mock_req.created_at = _now
    mock_req.updated_at = _now

    mock_svc = MagicMock()
    mock_svc.id = svc_id
    mock_svc.name = "my-svc"

    fake_arn = "arn:aws:secretsmanager:us-east-1:123:secret:platform/my-svc/dev/db-pass"

    mock_secret_request_repo = MagicMock(spec=SecretRequestRepository)
    mock_request_event_repo = MagicMock(spec=RequestEventRepository)
    mock_service_repo = MagicMock(spec=ServiceRepository)
    mock_secrets_manager = MagicMock(spec=SecretsManager)
    mock_secret_request_repo.get_for_update.return_value = mock_req
    mock_service_repo.get_by_id.return_value = mock_svc
    mock_secrets_manager.create_app_secret.return_value = fake_arn

    svc = SecretRequestLifecycleService(
        db=MagicMock(),
        secrets_manager=mock_secrets_manager,
        secret_request_repo=mock_secret_request_repo,
        request_event_repo=mock_request_event_repo,
        service_repo=mock_service_repo,
    )

    app.dependency_overrides[get_secret_request_lifecycle_service] = lambda: svc
    try:
        with structlog.testing.capture_logs() as logs:
            client.post(
                f"/api/v1/secret-requests/{req_id}/approve",
                json={"approver_email": "ops@co.com"},
            )
    finally:
        app.dependency_overrides.clear()

    outcome_logs = [e for e in logs if e.get("event") == "secret_provisioning_outcome"]
    assert len(outcome_logs) == 1
    entry = outcome_logs[0]
    assert entry["outcome"] == "provisioned"
    assert "request_id" in entry
    assert "environment" in entry


def test_provisioning_outcome_failed_event_shape() -> None:
    """The FAILED outcome must emit secret_provisioning_outcome with outcome=failed."""
    from app.src.repositories.request_event_repository import RequestEventRepository
    from app.src.repositories.secret_request_repository import SecretRequestRepository
    from app.src.repositories.service_repository import ServiceRepository
    from app.src.services.dependencies import get_secret_request_lifecycle_service
    from app.src.services.secret_request_lifecycle_service import SecretRequestLifecycleService
    from app.src.services.secrets_manager_service import SecretsManager

    svc_id = uuid.uuid4()
    req_id = uuid.uuid4()

    _now = datetime(2026, 6, 14, tzinfo=UTC)
    mock_req = MagicMock()
    mock_req.id = req_id
    mock_req.service_id = svc_id
    mock_req.status = "PENDING"
    mock_req.logical_name = "db-pass"
    mock_req.environment = "dev"
    mock_req.description = None
    mock_req.secret_arn = None
    mock_req.created_at = _now
    mock_req.updated_at = _now

    mock_svc = MagicMock()
    mock_svc.id = svc_id
    mock_svc.name = "my-svc"

    mock_secret_request_repo = MagicMock(spec=SecretRequestRepository)
    mock_request_event_repo = MagicMock(spec=RequestEventRepository)
    mock_service_repo = MagicMock(spec=ServiceRepository)
    mock_secrets_manager = MagicMock(spec=SecretsManager)
    mock_secret_request_repo.get_for_update.return_value = mock_req
    mock_service_repo.get_by_id.return_value = mock_svc
    mock_secrets_manager.create_app_secret.side_effect = RuntimeError("boom")

    svc = SecretRequestLifecycleService(
        db=MagicMock(),
        secrets_manager=mock_secrets_manager,
        secret_request_repo=mock_secret_request_repo,
        request_event_repo=mock_request_event_repo,
        service_repo=mock_service_repo,
    )

    app.dependency_overrides[get_secret_request_lifecycle_service] = lambda: svc
    try:
        with structlog.testing.capture_logs() as logs:
            client.post(
                f"/api/v1/secret-requests/{req_id}/approve",
                json={"approver_email": "ops@co.com"},
            )
    finally:
        app.dependency_overrides.clear()

    outcome_logs = [e for e in logs if e.get("event") == "secret_provisioning_outcome"]
    assert len(outcome_logs) == 1
    assert outcome_logs[0]["outcome"] == "failed"
    assert "error" in outcome_logs[0]
