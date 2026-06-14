"""Unit tests for Pydantic schemas — no DB required."""

import uuid
from datetime import UTC

import pytest
from pydantic import ValidationError

from app.src.schemas.secret_request import SecretRequestCreate, SecretRequestRead
from app.src.schemas.service import ServiceCreate, ServiceRead


class TestServiceCreate:
    def test_valid(self) -> None:
        svc = ServiceCreate(name="claims-api", team="claims", owner_email="eng@co.com")
        assert svc.name == "claims-api"
        assert svc.repo_url is None

    def test_with_repo_url(self) -> None:
        svc = ServiceCreate(
            name="claims-api",
            team="claims",
            owner_email="eng@co.com",
            repo_url="https://github.com/org/repo",
        )
        assert svc.repo_url == "https://github.com/org/repo"

    def test_missing_required_field(self) -> None:
        with pytest.raises(ValidationError):
            ServiceCreate(name="x", team="y")  # type: ignore[call-arg]


class TestServiceRead:
    def test_from_attributes(self) -> None:
        class FakeORM:
            id = uuid.uuid4()
            name = "claims-api"
            team = "claims"
            owner_email = "eng@co.com"
            repo_url = None
            from datetime import datetime, timezone

            created_at = datetime.now(UTC)

        read = ServiceRead.model_validate(FakeORM(), from_attributes=True)
        assert isinstance(read.id, uuid.UUID)
        assert read.name == "claims-api"


class TestSecretRequestCreate:
    def test_valid_environments(self) -> None:
        base = {
            "service_id": uuid.uuid4(),
            "logical_name": "db-password",
        }
        for env in ("dev", "staging", "prod"):
            req = SecretRequestCreate(**base, environment=env)  # type: ignore[arg-type]
            assert req.environment == env

    def test_invalid_environment_rejected(self) -> None:
        with pytest.raises(ValidationError):
            SecretRequestCreate(
                service_id=uuid.uuid4(),
                logical_name="db-password",
                environment="production",  # type: ignore[arg-type]  # not a valid value
            )

    def test_missing_environment_rejected(self) -> None:
        with pytest.raises(ValidationError):
            SecretRequestCreate(
                service_id=uuid.uuid4(),
                logical_name="db-password",
            )  # type: ignore[call-arg]

    def test_optional_description(self) -> None:
        req = SecretRequestCreate(
            service_id=uuid.uuid4(),
            logical_name="api-key",
            environment="dev",
            description="Key for downstream calls",
        )
        assert req.description == "Key for downstream calls"


class TestSecretRequestRead:
    def test_invalid_status_in_read_schema(self) -> None:
        with pytest.raises(ValidationError):
            SecretRequestRead(
                id=uuid.uuid4(),
                service_id=uuid.uuid4(),
                logical_name="x",
                environment="dev",
                status="UNKNOWN",  # type: ignore[arg-type]
                secret_arn=None,
                description=None,
                created_at=__import__("datetime").datetime.now(),
                updated_at=__import__("datetime").datetime.now(),
            )
