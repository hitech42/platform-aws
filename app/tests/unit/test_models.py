"""Unit tests for ORM model construction — no DB required.

SQLAlchemy column `default=uuid.uuid4` is a column INSERT default: it fires
when the ORM emits the INSERT statement (at session.flush()), not at Python
object construction time. Tests here verify construction-time behaviour only;
UUID generation and DB constraints are verified in the integration tests.
"""

import uuid

from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import VALID_ENVIRONMENTS, VALID_STATUSES, SecretRequest
from app.src.models.service import Service


class TestServiceModel:
    def test_instantiation_sets_supplied_fields(self) -> None:
        svc = Service(name="auth-service", team="platform", owner_email="ops@co.com")
        assert svc.name == "auth-service"
        assert svc.team == "platform"
        assert svc.owner_email == "ops@co.com"
        assert svc.repo_url is None

    def test_id_is_none_before_flush(self) -> None:
        # Column INSERT default (uuid.uuid4) fires at flush time, not construction.
        svc = Service(name="x", team="y", owner_email="z@z.com")
        assert svc.id is None

    def test_explicit_id_accepted(self) -> None:
        eid = uuid.uuid4()
        svc = Service(id=eid, name="x", team="y", owner_email="z@z.com")
        assert svc.id == eid


class TestSecretRequestConstants:
    def test_valid_environments_tuple(self) -> None:
        assert set(VALID_ENVIRONMENTS) == {"dev", "staging", "prod"}

    def test_valid_statuses_tuple(self) -> None:
        assert set(VALID_STATUSES) == {
            "PENDING",
            "APPROVED",
            "PROVISIONING",
            "PROVISIONED",
            "FAILED",
        }


class TestSecretRequestModel:
    def test_instantiation(self) -> None:
        req = SecretRequest(
            service_id=uuid.uuid4(),
            logical_name="db-password",
            environment="dev",
        )
        assert req.logical_name == "db-password"
        assert req.environment == "dev"
        assert req.secret_arn is None

    def test_status_defaults_to_none_before_flush(self) -> None:
        # server_default='PENDING' is a DDL default, applied by the DB at INSERT time.
        req = SecretRequest(
            service_id=uuid.uuid4(),
            logical_name="x",
            environment="staging",
        )
        assert req.status is None  # not yet written to DB


class TestRequestEventModel:
    def test_instantiation(self) -> None:
        ev = RequestEvent(
            secret_request_id=uuid.uuid4(),
            status="APPROVED",
            actor="approver@co.com",
        )
        assert ev.actor == "approver@co.com"
        assert ev.detail is None
