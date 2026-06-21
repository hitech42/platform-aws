import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.src.models.request_event import RequestEvent


class RequestEventRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def create(
        self,
        secret_request_id: uuid.UUID,
        status: str,
        actor: str,
        detail: str | None,
    ) -> RequestEvent:
        """Insert an immutable audit event row and flush. Does not commit."""
        event = RequestEvent(
            secret_request_id=secret_request_id,
            status=status,
            actor=actor,
            detail=detail,
        )
        self._db.add(event)
        self._db.flush()
        return event

    def list_for_request(self, secret_request_id: uuid.UUID) -> list[RequestEvent]:
        """Return all events for a request ordered by timestamp then seq (tiebreaker)."""
        return list(
            self._db.execute(
                select(RequestEvent)
                .where(RequestEvent.secret_request_id == secret_request_id)
                .order_by(RequestEvent.timestamp.asc(), RequestEvent.seq.asc())
            )
            .scalars()
            .all()
        )
