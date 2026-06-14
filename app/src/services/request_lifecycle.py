"""State machine for secret-request lifecycle transitions.

Valid transitions:
    PENDING → APPROVED
    APPROVED → PROVISIONING
    PROVISIONING → PROVISIONED
    PROVISIONING → FAILED

All other transitions are rejected with InvalidStateError.
Functions flush but never commit — the caller controls the transaction boundary.
"""

import structlog
from sqlalchemy.orm import Session

from app.src.core.exceptions import InvalidStateError
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest

log = structlog.get_logger(__name__)

VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "PENDING": frozenset({"APPROVED"}),
    "APPROVED": frozenset({"PROVISIONING"}),
    "PROVISIONING": frozenset({"PROVISIONED", "FAILED"}),
    "PROVISIONED": frozenset(),
    "FAILED": frozenset(),
}


def transition(
    db: Session,
    request: SecretRequest,
    new_status: str,
    actor: str,
    detail: str | None = None,
) -> RequestEvent:
    """Validate and apply a status transition, writing an immutable audit event.

    Raises InvalidStateError if the transition is not permitted.
    Flushes both the updated SecretRequest and the new RequestEvent — does not commit.
    """
    allowed = VALID_TRANSITIONS.get(request.status, frozenset())
    if new_status not in allowed:
        raise InvalidStateError(
            f"Cannot transition from '{request.status}' to '{new_status}'."
        )

    from_status = request.status
    request.status = new_status

    event = RequestEvent(
        secret_request_id=request.id,
        status=new_status,
        actor=actor,
        detail=detail,
    )
    db.add(event)
    db.flush()

    log.info(
        "secret_request.transition",
        request_id=str(request.id),
        from_status=from_status,
        to_status=new_status,
        actor=actor,
    )
    return event
