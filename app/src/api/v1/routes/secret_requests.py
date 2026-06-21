"""Routes for secret-request lifecycle.

Paths are defined in full here (no router-level prefix) because the resource
appears under two different base paths:
  POST  /services/{service_id}/secret-requests   (nested under service)
  GET   /secret-requests/{request_id}
  GET   /secret-requests/{request_id}/events
  POST  /secret-requests/{request_id}/approve
  GET   /secret-requests/{request_id}/summary
"""

import uuid

from fastapi import APIRouter, Depends, Request

from app.src.schemas.secret_request import (
    ApproveRequest,
    RequestEventRead,
    SecretRequestBody,
    SecretRequestRead,
    SecretRequestSummaryRead,
)
from app.src.services.dependencies import (
    get_narrative_service,
    get_secret_request_lifecycle_service,
)
from app.src.services.narrative_service import NarrativeService
from app.src.services.secret_request_lifecycle_service import SecretRequestLifecycleService

router = APIRouter(tags=["secret-requests"])


@router.post(
    "/services/{service_id}/secret-requests",
    status_code=201,
    response_model=SecretRequestRead,
)
def create_secret_request(
    service_id: uuid.UUID,
    body: SecretRequestBody,
    svc: SecretRequestLifecycleService = Depends(get_secret_request_lifecycle_service),
) -> SecretRequestRead:
    req = svc.create_request(service_id, body)
    return SecretRequestRead.model_validate(req)


@router.get("/secret-requests/{request_id}", response_model=SecretRequestRead)
def get_secret_request(
    request_id: uuid.UUID,
    svc: SecretRequestLifecycleService = Depends(get_secret_request_lifecycle_service),
) -> SecretRequestRead:
    req = svc.get_request(request_id)
    return SecretRequestRead.model_validate(req)


@router.get(
    "/secret-requests/{request_id}/events",
    response_model=list[RequestEventRead],
)
def list_events(
    request_id: uuid.UUID,
    svc: SecretRequestLifecycleService = Depends(get_secret_request_lifecycle_service),
) -> list[RequestEventRead]:
    events = svc.get_events(request_id)
    return [RequestEventRead.model_validate(e) for e in events]


@router.post("/secret-requests/{request_id}/approve", response_model=SecretRequestRead)
def approve_secret_request(
    request_id: uuid.UUID,
    body: ApproveRequest,
    request: Request,
    svc: SecretRequestLifecycleService = Depends(get_secret_request_lifecycle_service),
) -> SecretRequestRead:
    result = svc.approve_request(request_id, body.approver_email)
    # Set from_status/to_status on request.state for RequestLoggingMiddleware.
    request.state.from_status = result.from_status
    request.state.to_status = result.request.status
    return SecretRequestRead.model_validate(result.request)


@router.get(
    "/secret-requests/{request_id}/summary",
    response_model=SecretRequestSummaryRead,
)
def get_secret_request_summary(
    request_id: uuid.UUID,
    svc: NarrativeService = Depends(get_narrative_service),
) -> SecretRequestSummaryRead:
    """Return deterministic risk facts plus an LLM-generated narrative.

    Facts are always present regardless of LLM availability. The narrative
    may be null if the active provider fails — expected degraded state.
    Switch providers via a psql UPDATE to the config table; takes effect
    within 30 seconds, no redeploy needed.
    """
    return svc.generate_summary(request_id)
