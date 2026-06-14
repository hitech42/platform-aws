"""Integration tests for service catalog endpoints.

Uses testcontainers Postgres (see conftest.py) — does NOT touch the
developer's locally-running Postgres. Requires Docker.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from app.src.db.session import get_db
from app.src.main import app


def _make_client(db_engine: object) -> TestClient:
    """Return a TestClient whose get_db dependency points at the test DB."""
    from sqlalchemy import Engine

    assert isinstance(db_engine, Engine)
    session_factory = sessionmaker(bind=db_engine)

    def override_get_db() -> Session:  # type: ignore[misc]
        db = session_factory()
        try:
            yield db  # type: ignore[misc]
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app)


# ── POST /api/v1/services ──────────────────────────────────────────────────────


def test_create_service_returns_201(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        payload = {
            "name": f"svc-{uuid.uuid4().hex[:8]}",
            "team": "platform",
            "owner_email": "eng@co.com",
        }
        r = client.post("/api/v1/services", json=payload)
        assert r.status_code == 201
        data = r.json()
        assert data["name"] == payload["name"]
        assert data["team"] == "platform"
        assert "id" in data
        assert "created_at" in data
        assert data["repo_url"] is None
    finally:
        app.dependency_overrides.clear()


def test_create_service_with_repo_url(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        r = client.post(
            "/api/v1/services",
            json={
                "name": f"svc-{uuid.uuid4().hex[:8]}",
                "team": "claims",
                "owner_email": "ops@co.com",
                "repo_url": "https://github.com/org/repo",
            },
        )
        assert r.status_code == 201
        assert r.json()["repo_url"] == "https://github.com/org/repo"
    finally:
        app.dependency_overrides.clear()


def test_create_service_duplicate_name_returns_409(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        name = f"dup-{uuid.uuid4().hex[:8]}"
        client.post("/api/v1/services", json={"name": name, "team": "a", "owner_email": "a@a.com"})
        r = client.post(
            "/api/v1/services", json={"name": name, "team": "b", "owner_email": "b@b.com"}
        )
        assert r.status_code == 409
        err = r.json()["error"]
        assert err["code"] == "CONFLICT"
        assert err["field"] == "name"
    finally:
        app.dependency_overrides.clear()


def test_create_service_missing_required_field_returns_422(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        r = client.post("/api/v1/services", json={"name": "x"})  # missing team, owner_email
        assert r.status_code == 422
        assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    finally:
        app.dependency_overrides.clear()


# ── GET /api/v1/services ───────────────────────────────────────────────────────


def test_list_services_returns_paginated_response(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        # Create two services to ensure at least something is returned.
        for _ in range(2):
            name = f"list-svc-{uuid.uuid4().hex[:6]}"
            client.post(
                "/api/v1/services",
                json={"name": name, "team": "t", "owner_email": "t@t.com"},
            )
        r = client.get("/api/v1/services?page=1&page_size=50")
        assert r.status_code == 200
        body = r.json()
        assert "items" in body
        assert "total" in body
        assert body["page"] == 1
        assert body["page_size"] == 50
        assert body["total"] >= 2
    finally:
        app.dependency_overrides.clear()


def test_list_services_page_size_capped_at_100(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        r = client.get("/api/v1/services?page_size=999")
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_list_services_page_beyond_data_returns_empty_items(db_engine: object) -> None:
    # page_size > 100 is rejected (422) — see test_list_services_page_size_capped_at_100.
    # page beyond the last row of data is NOT an error: it returns items=[] and the
    # true total so callers can detect they've read past the end.
    client = _make_client(db_engine)
    try:
        r = client.get("/api/v1/services?page=99999&page_size=100")
        assert r.status_code == 200
        body = r.json()
        assert body["items"] == []
        assert body["page"] == 99999
        assert body["page_size"] == 100
        assert isinstance(body["total"], int)
    finally:
        app.dependency_overrides.clear()


def test_list_services_pagination_offsets_correctly(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        names = [f"pg-{uuid.uuid4().hex[:6]}" for _ in range(3)]
        for name in names:
            client.post(
                "/api/v1/services",
                json={"name": name, "team": "t", "owner_email": "t@t.com"},
            )

        r1 = client.get("/api/v1/services?page=1&page_size=1")
        r2 = client.get("/api/v1/services?page=2&page_size=1")
        assert r1.status_code == 200
        assert r2.status_code == 200
        ids_p1 = {i["id"] for i in r1.json()["items"]}
        ids_p2 = {i["id"] for i in r2.json()["items"]}
        assert ids_p1.isdisjoint(ids_p2)
    finally:
        app.dependency_overrides.clear()


# ── GET /api/v1/services/{service_id} ─────────────────────────────────────────


def test_get_service_returns_200(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        name = f"get-{uuid.uuid4().hex[:8]}"
        created = client.post(
            "/api/v1/services",
            json={"name": name, "team": "eng", "owner_email": "eng@co.com"},
        ).json()
        r = client.get(f"/api/v1/services/{created['id']}")
        assert r.status_code == 200
        assert r.json()["id"] == created["id"]
        assert r.json()["name"] == name
    finally:
        app.dependency_overrides.clear()


def test_get_service_unknown_id_returns_404(db_engine: object) -> None:
    client = _make_client(db_engine)
    try:
        r = client.get(f"/api/v1/services/{uuid.uuid4()}")
        assert r.status_code == 404
        err = r.json()["error"]
        assert err["code"] == "NOT_FOUND"
        assert err["field"] == "service_id"
    finally:
        app.dependency_overrides.clear()
