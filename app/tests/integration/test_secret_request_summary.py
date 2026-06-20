"""Integration tests for GET /api/v1/secret-requests/{id}/summary.

Verifies that deterministic risk facts are computed correctly from real DB data
and that Bedrock failures never corrupt or suppress those facts.

generate_request_narrative is mocked throughout — the integration suite tests the
HTTP/DB layer, not AWS. Bedrock unit tests live in tests/unit/test_bedrock.py.
"""

import uuid
from unittest.mock import patch

from fastapi.testclient import TestClient

_STUB_NARRATIVE = "Stub narrative returned by mock for integration test."


def _create_service(client: TestClient, owner_email: str = "owner@co.com") -> dict:  # type: ignore[type-arg]
    name = f"svc-{uuid.uuid4().hex[:8]}"
    r = client.post(
        "/api/v1/services",
        json={"name": name, "team": "platform", "owner_email": owner_email},
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


# ── GET /api/v1/secret-requests/{id}/summary ─────────────────────────────────


def test_summary_ownership_mismatch_flag_is_set(client: TestClient) -> None:
    """Core fact: requester != service owner always sets ownership_mismatch=True.

    This is the primary Stage 5 assertion: facts are deterministic and derived
    from DB data, never from Bedrock output.
    """
    svc = _create_service(client, owner_email="alice@co.com")
    req = _create_request(client, svc["id"], requested_by="bob@co.com")

    with patch(
        "app.src.api.v1.routes.secret_requests.generate_request_narrative",
        return_value=(_STUB_NARRATIVE, None),
    ):
        r = client.get(f"/api/v1/secret-requests/{req['id']}/summary")

    assert r.status_code == 200
    data = r.json()
    assert data["id"] == req["id"]
    assert data["facts"]["ownership_mismatch"] is True
    assert data["facts"]["has_any_flag"] is True
    assert data["facts"]["naming_violations"] == []
    assert data["facts"]["is_production"] is False
    assert data["narrative"] == _STUB_NARRATIVE


def test_summary_no_flags_when_owner_requests_clean_name(client: TestClient) -> None:
    """All flags are clear when the service owner requests a well-named dev secret."""
    svc = _create_service(client, owner_email="alice@co.com")
    req = _create_request(
        client,
        svc["id"],
        logical_name="api-key",
        environment="dev",
        requested_by="alice@co.com",
    )

    with patch(
        "app.src.api.v1.routes.secret_requests.generate_request_narrative",
        return_value=(_STUB_NARRATIVE, None),
    ):
        r = client.get(f"/api/v1/secret-requests/{req['id']}/summary")

    assert r.status_code == 200
    facts = r.json()["facts"]
    assert facts["ownership_mismatch"] is False
    assert facts["naming_violations"] == []
    assert facts["is_production"] is False
    assert facts["has_any_flag"] is False


def test_summary_production_flag_is_set(client: TestClient) -> None:
    """is_production=True for prod environment regardless of who requested it."""
    svc = _create_service(client, owner_email="alice@co.com")
    req = _create_request(
        client,
        svc["id"],
        logical_name="api-key",
        environment="prod",
        requested_by="alice@co.com",
    )

    with patch(
        "app.src.api.v1.routes.secret_requests.generate_request_narrative",
        return_value=(_STUB_NARRATIVE, None),
    ):
        r = client.get(f"/api/v1/secret-requests/{req['id']}/summary")

    assert r.status_code == 200
    facts = r.json()["facts"]
    assert facts["is_production"] is True
    assert facts["has_any_flag"] is True


def test_summary_narrative_error_does_not_affect_facts(client: TestClient) -> None:
    """When Bedrock fails, facts are still correct and narrative_error is populated."""
    svc = _create_service(client, owner_email="alice@co.com")
    req = _create_request(client, svc["id"], requested_by="bob@co.com")

    with patch(
        "app.src.api.v1.routes.secret_requests.generate_request_narrative",
        return_value=(None, "AccessDeniedException: User is not authorized to invoke Bedrock"),
    ):
        r = client.get(f"/api/v1/secret-requests/{req['id']}/summary")

    assert r.status_code == 200
    data = r.json()
    # Facts must be correct even when Bedrock is unavailable.
    assert data["facts"]["ownership_mismatch"] is True
    assert data["facts"]["has_any_flag"] is True
    # Narrative fields reflect the Bedrock failure gracefully.
    assert data["narrative"] is None
    assert data["narrative_generated_by"] is None
    assert "AccessDeniedException" in (data["narrative_error"] or "")


def test_summary_not_found_returns_404(client: TestClient) -> None:
    r = client.get(f"/api/v1/secret-requests/{uuid.uuid4()}/summary")
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "NOT_FOUND"
