"""Service layer for secret-request CRUD.

Route handlers call these functions and own the commit; functions only flush.
"""

import uuid

import structlog
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.src.core.exceptions import ConflictError, NotFoundError, ValidationError
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.schemas.secret_request import SecretRequestBody
from app.src.services import service_catalog

log = structlog.get_logger(__name__)


def create_request(
    db: Session,
    service_id: uuid.UUID,
    body: SecretRequestBody,
) -> SecretRequest:
    """Create a new secret request in PENDING state and write the initial audit event.

    Raises:
        NotFoundError: if service_id does not exist.
        ValidationError: if generate_value is False.
        ConflictError: if an active request for the same (service, logical_name, environment) exists.
    """
    service_catalog.get_service(db, service_id)  # 404 if not found

    if not body.generate_value:
        raise ValidationError(
            "Caller-supplied secret values are not supported; set generate_value=true.",
            field="generate_value",
        )

    existing = db.execute(
        select(SecretRequest).where(
            SecretRequest.service_id == service_id,
            SecretRequest.logical_name == body.logical_name,
            SecretRequest.environment == body.environment,
        )
    ).scalar_one_or_none()
    if existing is not None:
        raise ConflictError(
            f"A secret request for '{body.logical_name}' in '{body.environment}' already exists for this service.",
            field="logical_name",
        )

    request = SecretRequest(
        service_id=service_id,
        logical_name=body.logical_name,
        environment=body.environment,
        description=body.description,
        status="PENDING",
    )
    db.add(request)
    db.flush()

    event = RequestEvent(
        secret_request_id=request.id,
        status="PENDING",
        actor=body.requested_by or "api",
        detail=None,
    )
    db.add(event)
    db.flush()

    log.info("secret_request.created", request_id=str(request.id), service_id=str(service_id))
    return request


def get_request(db: Session, request_id: uuid.UUID) -> SecretRequest:
    req = db.execute(
        select(SecretRequest).where(SecretRequest.id == request_id)
    ).scalar_one_or_none()
    if req is None:
        raise NotFoundError(f"Secret request '{request_id}' not found.", field="request_id")
    return req


def list_events(db: Session, request_id: uuid.UUID) -> list[RequestEvent]:
    get_request(db, request_id)  # 404 if request not found
    rows = db.execute(
        select(RequestEvent)
        .where(RequestEvent.secret_request_id == request_id)
        .order_by(RequestEvent.timestamp.asc())
    ).scalars().all()
    return list(rows)
