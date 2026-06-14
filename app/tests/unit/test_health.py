"""Unit tests for health endpoints — no DB required."""

from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.src.db.session import get_db
from app.src.main import app


def test_healthz_always_200() -> None:
    client = TestClient(app)
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_returns_200_with_db_field_when_db_ok() -> None:
    def working_db() -> MagicMock:  # type: ignore[misc]
        db = MagicMock()
        yield db

    app.dependency_overrides[get_db] = working_db
    try:
        client = TestClient(app)
        response = client.get("/readyz")
        assert response.status_code == 200
        assert response.json() == {"status": "ok", "db": "ok"}
    finally:
        app.dependency_overrides.clear()


def test_readyz_returns_503_when_db_raises() -> None:
    def failing_db() -> MagicMock:  # type: ignore[misc]
        db = MagicMock()
        db.execute.side_effect = Exception("connection refused")
        yield db

    app.dependency_overrides[get_db] = failing_db
    try:
        client = TestClient(app)
        response = client.get("/readyz")
        assert response.status_code == 503
        assert response.json() == {"status": "error", "db": "unreachable"}
    finally:
        app.dependency_overrides.clear()
