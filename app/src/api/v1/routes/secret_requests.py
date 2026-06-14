"""Routes for secret-request lifecycle.

Paths are defined in full here (no router-level prefix) because the resource
appears under two different base paths:
  POST  /services/{service_id}/secret-requests   (nested under service)
  GET   /secret-requests/{request_id}
  GET   /secret-requests/{request_id}/events
  POST  /secret-requests/{request_id}/approve
"""

import uuid

import structlog
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.src.db.session import get_db
from app.src.schemas.secret_request import (
    ApproveRequest,
    RequestEventRead,
    SecretRequestBody,
    SecretRequestRead,
)
from app.src.services import request_lifecycle, secret_requests as secret_requests_svc
from app.src.services import secrets_manager as secrets_manager_svc
from app.src.services import service_catalog

log = structlog.get_logger(__name__)

router = APIRouter(tags=["secret-requests"])


@router.post(
    "/services/{service_id}/secret-requests",
    status_code=201,
    response_model=SecretRequestRead,
)
def create_secret_request(
    service_id: uuid.UUID,
    body: SecretRequestBody,
    db: Session = Depends(get_db),
) -> SecretRequestRead:
    req = secret_requests_svc.create_request(db, service_id, body)
    db.commit()
    db.refresh(req)
    return SecretRequestRead.model_validate(req)


@router.get("/secret-requests/{request_id}", response_model=SecretRequestRead)
def get_secret_request(
    request_id: uuid.UUID,
    db: Session = Depends(get_db),
) -> SecretRequestRead:
    req = secret_requests_svc.get_request(db, request_id)
    return SecretRequestRead.model_validate(req)


@router.get(
    "/secret-requests/{request_id}/events",
    response_model=list[RequestEventRead],
)
def list_events(
    request_id: uuid.UUID,
    db: Session = Depends(get_db),
) -> list[RequestEventRead]:
    events = secret_requests_svc.list_events(db, request_id)
    return [RequestEventRead.model_validate(e) for e in events]


@router.post("/secret-requests/{request_id}/approve", response_model=SecretRequestRead)
def approve_secret_request(
    request_id: uuid.UUID,
    body: ApproveRequest,
    db: Session = Depends(get_db),
) -> SecretRequestRead:
    req = secret_requests_svc.get_request(db, request_id, for_update=True)
    service = service_catalog.get_service(db, req.service_id)

    # Validate state and move to PROVISIONING — commit so the state is durable
    # before the external AWS call begins.
    request_lifecycle.transition(db, req, "APPROVED", actor=body.approver_email)
    request_lifecycle.transition(db, req, "PROVISIONING", actor="system")
    db.commit()
    db.refresh(req)

    # Call Secrets Manager; record PROVISIONED or FAILED regardless of outcome.
    try:
        arn = secrets_manager_svc.create_app_secret(
            service_name=service.name,
            logical_name=req.logical_name,
            environment=req.environment,
            generate_value=True,
            description=req.description,
        )
        req.secret_arn = arn
        request_lifecycle.transition(db, req, "PROVISIONED", actor="system", detail=arn)
        log.info("secret_request.provisioned", request_id=str(req.id), arn=arn)
    except Exception as exc:
        detail = str(exc)[:2000]
        request_lifecycle.transition(db, req, "FAILED", actor="system", detail=detail)
        log.warning("secret_request.provisioning_failed", request_id=str(req.id), error=detail)

    db.commit()
    db.refresh(req)
    return SecretRequestRead.model_validate(req)
