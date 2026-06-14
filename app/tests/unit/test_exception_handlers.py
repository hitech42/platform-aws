"""Unit tests for global exception handlers and the exceptions module."""

from fastapi import APIRouter
from fastapi.testclient import TestClient

from app.src.core.exceptions import (
    AppError,
    ConflictError,
    InvalidStateError,
    NotFoundError,
    ValidationError,
)
from app.src.main import app

# ── Mount throwable test routes onto the real app ──────────────────────────────
# These routes exist only in tests; they give the exception handlers something
# concrete to catch without requiring DB or service wiring.

_test_router = APIRouter(prefix="/_test", include_in_schema=False)


@_test_router.get("/not-found")
async def _raise_not_found() -> None:
    raise NotFoundError("Service xyz not found", field="service_id")


@_test_router.get("/conflict")
async def _raise_conflict() -> None:
    raise ConflictError("Name already taken", field="name")


@_test_router.get("/invalid-state")
async def _raise_invalid_state() -> None:
    raise InvalidStateError("Request is not in PENDING state", field="status")


@_test_router.get("/validation")
async def _raise_validation() -> None:
    raise ValidationError("generate_value must be true", field="generate_value")


@_test_router.post("/body-validation")
async def _body_validation(payload: dict) -> None:  # type: ignore[type-arg]
    pass


@_test_router.get("/unhandled")
async def _raise_unhandled() -> None:
    raise RuntimeError("something completely unexpected")


app.include_router(_test_router)
client = TestClient(app)


# ── Exception class tests ──────────────────────────────────────────────────────


def test_not_found_error_attributes() -> None:
    exc = NotFoundError("thing not found", field="id")
    assert exc.status_code == 404
    assert exc.code == "NOT_FOUND"
    assert exc.message == "thing not found"
    assert exc.field == "id"


def test_conflict_error_attributes() -> None:
    exc = ConflictError("duplicate")
    assert exc.status_code == 409
    assert exc.code == "CONFLICT"
    assert exc.field is None


def test_invalid_state_error_attributes() -> None:
    exc = InvalidStateError("bad transition", field="status")
    assert exc.status_code == 409
    assert exc.code == "INVALID_STATE"


def test_validation_error_attributes() -> None:
    exc = ValidationError("bad value", field="env")
    assert exc.status_code == 422
    assert exc.code == "VALIDATION_ERROR"


def test_all_domain_errors_are_app_errors() -> None:
    for cls in (NotFoundError, ConflictError, InvalidStateError, ValidationError):
        assert issubclass(cls, AppError)


# ── HTTP handler tests ─────────────────────────────────────────────────────────


def test_not_found_returns_404_with_standard_shape() -> None:
    r = client.get("/_test/not-found")
    assert r.status_code == 404
    body = r.json()
    assert body["error"]["code"] == "NOT_FOUND"
    assert body["error"]["field"] == "service_id"
    assert "message" in body["error"]


def test_conflict_returns_409() -> None:
    r = client.get("/_test/conflict")
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "CONFLICT"
    assert r.json()["error"]["field"] == "name"


def test_invalid_state_returns_409() -> None:
    r = client.get("/_test/invalid-state")
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "INVALID_STATE"


def test_service_validation_error_returns_422() -> None:
    r = client.get("/_test/validation")
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_field_absent_when_none() -> None:
    """field should not appear in the JSON body when it is None."""
    # ConflictError raised without field argument → no field key.
    exc = ConflictError("no field here")
    assert exc.field is None


def test_pydantic_request_validation_uses_standard_shape() -> None:
    """A missing/invalid request body should return our error shape, not FastAPI's default."""
    # POST to a route that expects a dict body but we send nothing
    r = client.post(
        "/_test/body-validation",
        content="not-json",
        headers={"content-type": "application/json"},
    )
    assert r.status_code == 422
    body = r.json()
    assert "error" in body
    assert body["error"]["code"] == "VALIDATION_ERROR"


def test_unhandled_exception_returns_500_with_standard_shape() -> None:
    """Any unhandled exception should produce our standard error shape, not FastAPI's default."""
    # raise_server_exceptions=False tells TestClient to let the exception handlers run
    # instead of re-raising the exception in the test process.
    no_raise_client = TestClient(app, raise_server_exceptions=False)
    r = no_raise_client.get("/_test/unhandled")
    assert r.status_code == 500
    body = r.json()
    assert "error" in body
    assert body["error"]["code"] == "INTERNAL_ERROR"
    # Internal error details must not leak to the caller
    assert "RuntimeError" not in body["error"]["message"]
    assert "something completely unexpected" not in body["error"]["message"]
