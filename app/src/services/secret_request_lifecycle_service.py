"""Secret-request lifecycle service.

Owns all state transitions, audit events, and the two-phase commit that
brackets the Secrets Manager call:

    COMMIT #1  after PENDING → APPROVED → PROVISIONING
               (durably records intent before the AWS call begins)
    COMMIT #2  after PROVISIONING → PROVISIONED | FAILED
               (records the outcome regardless of whether the AWS call succeeded)

This mirrors the original route-level commit structure exactly; only the
code location has moved (service layer now owns it, not the route handler).
"""

import uuid
from dataclasses import dataclass

import structlog
from sqlalchemy.orm import Session

from app.src.core.exceptions import ConflictError, InvalidStateError, NotFoundError, ValidationError
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.repositories.request_event_repository import RequestEventRepository
from app.src.repositories.secret_request_repository import SecretRequestRepository
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.secret_request import SecretRequestBody
from app.src.services.secrets_manager_service import SecretsManagerService

log = structlog.get_logger(__name__)


@dataclass
class ApproveResult:
    """Returned by approve_request so the route can set request.state fields."""

    request: SecretRequest
    from_status: str


class SecretRequestLifecycleService:
    _VALID_TRANSITIONS: dict[str, frozenset[str]] = {
        "PENDING": frozenset({"APPROVED"}),
        "APPROVED": frozenset({"PROVISIONING"}),
        "PROVISIONING": frozenset({"PROVISIONED", "FAILED"}),
        "PROVISIONED": frozenset(),
        "FAILED": frozenset(),
    }

    def __init__(
        self,
        db: Session,
        secrets_manager_service: SecretsManagerService,
        secret_request_repo: SecretRequestRepository,
        request_event_repo: RequestEventRepository,
        service_repo: ServiceRepository,
    ) -> None:
        self._db = db
        self._secrets_manager_service = secrets_manager_service
        self._secret_request_repo = secret_request_repo
        self._request_event_repo = request_event_repo
        self._service_repo = service_repo

    # ── public methods ─────────────────────────────────────────────────────────

    def create_request(self, service_id: uuid.UUID, body: SecretRequestBody) -> SecretRequest:
        if self._service_repo.get_by_id(service_id) is None:
            raise NotFoundError(f"Service '{service_id}' not found.", field="service_id")

        if not body.generate_value:
            raise ValidationError(
                "Caller-supplied secret values are not supported; set generate_value=true.",
                field="generate_value",
            )

        if self._secret_request_repo.exists_for_tuple(
            service_id, body.logical_name, body.environment
        ):
            raise ConflictError(
                f"A request for '{body.logical_name}' in '{body.environment}' already exists.",
                field="logical_name",
            )

        req = self._secret_request_repo.create(
            service_id=service_id,
            logical_name=body.logical_name,
            environment=body.environment,
            description=body.description,
        )
        self._request_event_repo.create(
            secret_request_id=req.id,
            status="PENDING",
            actor=body.requested_by or "api",
            detail=None,
        )
        self._db.commit()
        self._db.refresh(req)
        log.info("secret_request.created", request_id=str(req.id), service_id=str(service_id))
        return req

    def get_request(self, request_id: uuid.UUID) -> SecretRequest:
        req = self._secret_request_repo.get_by_id(request_id)
        if req is None:
            raise NotFoundError(f"Secret request '{request_id}' not found.", field="request_id")
        return req

    def get_events(self, request_id: uuid.UUID) -> list[RequestEvent]:
        if self._secret_request_repo.get_by_id(request_id) is None:
            raise NotFoundError(f"Secret request '{request_id}' not found.", field="request_id")
        return self._request_event_repo.list_for_request(request_id)

    def approve_request(self, request_id: uuid.UUID, approver_email: str) -> ApproveResult:
        """Approve and provision a secret request.

        Acquires a SELECT FOR UPDATE row lock before reading status so that two
        concurrent approve calls cannot both read PENDING and both proceed past
        the state-machine check.

        Returns ApproveResult with the request (at its final status) and the
        from_status captured at lock time, so the route can set request.state
        fields for the logging middleware without needing to re-read the row.
        """
        req = self._secret_request_repo.get_for_update(request_id)
        if req is None:
            raise NotFoundError(f"Secret request '{request_id}' not found.", field="request_id")

        from_status = req.status

        # Validate and move to PROVISIONING — both transitions flush but do not commit.
        self._transition(req, "APPROVED", actor=approver_email)
        self._transition(req, "PROVISIONING", actor="system")

        # COMMIT #1: make PROVISIONING durable before the external AWS call begins.
        # If the process crashes after this commit, the request stays PROVISIONING
        # (visible as an incomplete operation) rather than silently reverting to PENDING.
        self._db.commit()
        self._db.refresh(req)

        service = self._service_repo.get_by_id(req.service_id)
        # service_id is a FK; the service always exists here
        assert service is not None

        try:
            arn = self._secrets_manager_service.create_app_secret(
                service_name=service.name,
                logical_name=req.logical_name,
                environment=req.environment,
                generate_value=True,
                description=req.description,
            )
            self._secret_request_repo.set_secret_arn(req, arn)
            self._transition(req, "PROVISIONED", actor="system", detail=arn)
            # ↓ CloudWatch Logs metric filter target — do not change event name or outcome field.
            log.info(
                "secret_provisioning_outcome",
                outcome="provisioned",
                request_id=str(req.id),
                service_id=str(req.service_id),
                environment=req.environment,
                arn=arn,
            )
        except Exception as exc:
            detail = str(exc)[:2000]
            self._transition(req, "FAILED", actor="system", detail=detail)
            log.warning(
                "secret_provisioning_outcome",
                outcome="failed",
                request_id=str(req.id),
                service_id=str(req.service_id),
                environment=req.environment,
                error=detail,
            )

        # COMMIT #2: record PROVISIONED or FAILED.
        self._db.commit()
        self._db.refresh(req)

        return ApproveResult(request=req, from_status=from_status)

    # ── private helpers ────────────────────────────────────────────────────────

    def _transition(
        self,
        request: SecretRequest,
        new_status: str,
        actor: str,
        detail: str | None = None,
    ) -> RequestEvent:
        allowed = self._VALID_TRANSITIONS.get(request.status, frozenset())
        if new_status not in allowed:
            raise InvalidStateError(f"Cannot transition from '{request.status}' to '{new_status}'.")

        from_status = request.status
        request.status = new_status

        event = self._request_event_repo.create(
            secret_request_id=request.id,
            status=new_status,
            actor=actor,
            detail=detail,
        )
        log.info(
            "secret_request.transition",
            request_id=str(request.id),
            from_status=from_status,
            to_status=new_status,
            actor=actor,
        )
        return event
