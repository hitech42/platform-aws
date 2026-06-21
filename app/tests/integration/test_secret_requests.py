"""Integration tests for secret-request endpoints.

Secrets Manager calls are mocked — we test the HTTP/DB layer, not AWS.
LocalStack is exercised separately via docker-compose.
"""

import threading
import uuid
from unittest.mock import patch

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

# ── helpers ────────────────────────────────────────────────────────────────────


def _create_service(client: TestClient, suffix: str = "") -> dict:  # type: ignore[type-arg]
    name = f"svc-{uuid.uuid4().hex[:8]}{suffix}"
    r = client.post(
        "/api/v1/services",
        json={"name": name, "team": "platform", "owner_email": "eng@co.com"},
    )
    assert r.status_code == 201
    return r.json()


def _create_request(client: TestClient, service_id: str, **overrides: object) -> dict:  # type: ignore[type-arg]
    payload = {
        "logical_name": "db-password",
        "environment": "dev",
        "generate_value": True,
        **overrides,
    }
    r = client.post(f"/api/v1/services/{service_id}/secret-requests", json=payload)
    assert r.status_code == 201
    return r.json()


_FAKE_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:platform/svc/dev/db-password"


# ── POST /api/v1/services/{service_id}/secret-requests ────────────────────────


def test_create_secret_request_returns_201(client: TestClient) -> None:
    svc = _create_service(client)
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={"logical_name": "api-key", "environment": "staging", "generate_value": True},
    )
    assert r.status_code == 201
    data = r.json()
    assert data["status"] == "PENDING"
    assert data["service_id"] == svc["id"]
    assert data["logical_name"] == "api-key"
    assert data["environment"] == "staging"
    assert data["secret_arn"] is None
    assert "id" in data
    assert "created_at" in data


def test_create_secret_request_with_description(client: TestClient) -> None:
    svc = _create_service(client)
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={
            "logical_name": "jwt-secret",
            "environment": "prod",
            "generate_value": True,
            "description": "JWT signing secret",
        },
    )
    assert r.status_code == 201
    assert r.json()["description"] == "JWT signing secret"


def test_create_secret_request_service_not_found_returns_404(client: TestClient) -> None:
    r = client.post(
        f"/api/v1/services/{uuid.uuid4()}/secret-requests",
        json={"logical_name": "key", "environment": "dev", "generate_value": True},
    )
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "NOT_FOUND"


def test_create_secret_request_generate_value_false_returns_422(client: TestClient) -> None:
    svc = _create_service(client)
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={"logical_name": "key", "environment": "dev", "generate_value": False},
    )
    assert r.status_code == 422
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR"
    assert err["field"] == "generate_value"


def test_create_secret_request_duplicate_returns_409(client: TestClient) -> None:
    svc = _create_service(client)
    _create_request(client, svc["id"])
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={"logical_name": "db-password", "environment": "dev", "generate_value": True},
    )
    assert r.status_code == 409
    err = r.json()["error"]
    assert err["code"] == "CONFLICT"
    assert err["field"] == "logical_name"


def test_same_logical_name_different_environment_allowed(client: TestClient) -> None:
    svc = _create_service(client)
    _create_request(client, svc["id"], environment="dev")
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={"logical_name": "db-password", "environment": "staging", "generate_value": True},
    )
    assert r.status_code == 201


def test_create_secret_request_invalid_environment_returns_422(client: TestClient) -> None:
    svc = _create_service(client)
    r = client.post(
        f"/api/v1/services/{svc['id']}/secret-requests",
        json={"logical_name": "key", "environment": "qa", "generate_value": True},
    )
    assert r.status_code == 422


# ── GET /api/v1/secret-requests/{id} ──────────────────────────────────────────


def test_get_secret_request_returns_200(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"])
    r = client.get(f"/api/v1/secret-requests/{req['id']}")
    assert r.status_code == 200
    assert r.json()["id"] == req["id"]
    assert r.json()["status"] == "PENDING"


def test_get_secret_request_not_found_returns_404(client: TestClient) -> None:
    r = client.get(f"/api/v1/secret-requests/{uuid.uuid4()}")
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "NOT_FOUND"
    assert r.json()["error"]["field"] == "request_id"


# ── GET /api/v1/secret-requests/{id}/events ───────────────────────────────────


def test_list_events_has_pending_event_after_creation(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"], requested_by="requester@co.com")
    r = client.get(f"/api/v1/secret-requests/{req['id']}/events")
    assert r.status_code == 200
    events = r.json()
    assert len(events) == 1
    assert events[0]["status"] == "PENDING"
    assert events[0]["actor"] == "requester@co.com"


def test_list_events_not_found_returns_404(client: TestClient) -> None:
    r = client.get(f"/api/v1/secret-requests/{uuid.uuid4()}/events")
    assert r.status_code == 404


# ── POST /api/v1/secret-requests/{id}/approve ─────────────────────────────────


def test_approve_transitions_to_provisioned(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        return_value=_FAKE_ARN,
    ):
        r = client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "ops@co.com"},
        )

    assert r.status_code == 200
    data = r.json()
    assert data["status"] == "PROVISIONED"
    assert data["secret_arn"] == _FAKE_ARN


def test_approve_writes_full_event_trail(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        return_value=_FAKE_ARN,
    ):
        client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "approver@co.com"},
        )

    r = client.get(f"/api/v1/secret-requests/{req['id']}/events")
    assert r.status_code == 200
    events = r.json()
    statuses = [e["status"] for e in events]
    assert statuses == ["PENDING", "APPROVED", "PROVISIONING", "PROVISIONED"]
    approved_event = next(e for e in events if e["status"] == "APPROVED")
    assert approved_event["actor"] == "approver@co.com"


def test_approve_records_failed_when_secrets_manager_raises(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        side_effect=RuntimeError("AccessDenied"),
    ):
        r = client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "ops@co.com"},
        )

    assert r.status_code == 200
    data = r.json()
    assert data["status"] == "FAILED"
    assert data["secret_arn"] is None

    events = client.get(f"/api/v1/secret-requests/{req['id']}/events").json()
    statuses = [e["status"] for e in events]
    assert statuses == ["PENDING", "APPROVED", "PROVISIONING", "FAILED"]
    failed_event = next(e for e in events if e["status"] == "FAILED")
    assert "AccessDenied" in failed_event["detail"]


def test_approve_not_found_returns_404(client: TestClient) -> None:
    r = client.post(
        f"/api/v1/secret-requests/{uuid.uuid4()}/approve",
        json={"approver_email": "ops@co.com"},
    )
    assert r.status_code == 404


# ── event ordering and edge cases ─────────────────────────────────────────────


def test_list_events_returns_empty_list_when_no_events(
    client: TestClient,
    committed_db: Session,
) -> None:
    """A SecretRequest with zero events (not creatable via the API) returns 200 []."""
    from app.src.models.secret_request import SecretRequest

    # Create a service via the API so we have a valid FK target.
    svc = _create_service(client)

    # Insert a raw SecretRequest without going through create_request(), which
    # would normally write a PENDING event. Commit immediately so the client's
    # separate session can see the row.
    raw_req = SecretRequest(
        service_id=uuid.UUID(svc["id"]),
        logical_name="no-events-key",
        environment="dev",
        status="PENDING",
    )
    committed_db.add(raw_req)
    committed_db.flush()
    req_id = raw_req.id
    committed_db.commit()

    r = client.get(f"/api/v1/secret-requests/{req_id}/events")
    assert r.status_code == 200
    assert r.json() == []


def test_list_events_ordering_preserved_for_same_second_events(
    client: TestClient,
) -> None:
    """Events written in the same DB transaction share a timestamp; seq ensures order."""
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        return_value=_FAKE_ARN,
    ):
        client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "approver@co.com"},
        )

    events = client.get(f"/api/v1/secret-requests/{req['id']}/events").json()
    statuses = [e["status"] for e in events]
    # APPROVED and PROVISIONING are flushed in the same transaction and therefore
    # share an identical now() timestamp; the seq tiebreaker must keep them ordered.
    assert statuses == ["PENDING", "APPROVED", "PROVISIONING", "PROVISIONED"]


def test_approve_failed_detail_is_truncated_and_contains_no_traceback(
    client: TestClient,
) -> None:
    """The FAILED event detail must be ≤ 2000 chars and must not expose stack traces."""
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    long_message = "X" * 5000

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        side_effect=RuntimeError(long_message),
    ):
        r = client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "ops@co.com"},
        )

    assert r.status_code == 200
    assert r.json()["status"] == "FAILED"

    events = client.get(f"/api/v1/secret-requests/{req['id']}/events").json()
    failed = next(e for e in events if e["status"] == "FAILED")
    assert len(failed["detail"]) <= 2000
    assert "Traceback" not in (failed["detail"] or "")
    assert "File " not in (failed["detail"] or "")


def test_approve_concurrent_calls_second_gets_409(client: TestClient) -> None:
    """SELECT FOR UPDATE prevents double-provisioning under concurrent approve calls."""
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    results: list[int] = []
    lock = threading.Lock()
    # Barrier ensures both threads enter the HTTP call at the same instant,
    # maximising the chance that both DB transactions overlap.
    barrier = threading.Barrier(2)

    def approve() -> None:
        barrier.wait()
        r = client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "ops@co.com"},
        )
        with lock:
            results.append(r.status_code)

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        return_value=_FAKE_ARN,
    ):
        t1 = threading.Thread(target=approve)
        t2 = threading.Thread(target=approve)
        t1.start()
        t2.start()
        t1.join(timeout=30)
        t2.join(timeout=30)

    assert sorted(results) == [200, 409], f"Expected exactly one 200 and one 409, got {results}"


def test_approve_non_pending_request_returns_409(client: TestClient) -> None:
    svc = _create_service(client)
    req = _create_request(client, svc["id"])

    with patch(
        "app.src.services.secrets_manager_service.SecretsManager.create_app_secret",
        return_value=_FAKE_ARN,
    ):
        client.post(
            f"/api/v1/secret-requests/{req['id']}/approve",
            json={"approver_email": "ops@co.com"},
        )

    # Second approve on a now-PROVISIONED request should fail
    r = client.post(
        f"/api/v1/secret-requests/{req['id']}/approve",
        json={"approver_email": "ops@co.com"},
    )
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "INVALID_STATE"
