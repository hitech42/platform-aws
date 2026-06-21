import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.src.models.secret_request import SecretRequest


class SecretRequestRepository:
    def __init__(self, db: Session) -> None:
        self.db = db

    def create(
        self,
        service_id: uuid.UUID,
        logical_name: str,
        environment: str,
        description: str | None,
        status: str = "PENDING",
    ) -> SecretRequest:
        req = SecretRequest(
            service_id=service_id,
            logical_name=logical_name,
            environment=environment,
            description=description,
            status=status,
        )
        self.db.add(req)
        self.db.flush()
        return req

    def get_by_id(self, id: uuid.UUID) -> SecretRequest | None:
        return self.db.execute(
            select(SecretRequest).where(SecretRequest.id == id)
        ).scalar_one_or_none()

    def get_for_update(self, id: uuid.UUID) -> SecretRequest | None:
        """SELECT ... FOR UPDATE — acquires a row lock for the approve flow.

        The caller must hold the returned object and use it for all subsequent
        status mutations within the same transaction. Do not issue a second
        unlocked read between this call and the status check; that would
        reintroduce the race condition this lock prevents.
        """
        return self.db.execute(
            select(SecretRequest).where(SecretRequest.id == id).with_for_update()
        ).scalar_one_or_none()

    def exists_for_tuple(
        self,
        service_id: uuid.UUID,
        logical_name: str,
        environment: str,
    ) -> bool:
        result = self.db.execute(
            select(SecretRequest).where(
                SecretRequest.service_id == service_id,
                SecretRequest.logical_name == logical_name,
                SecretRequest.environment == environment,
            )
        ).scalar_one_or_none()
        return result is not None

    def set_secret_arn(self, request: SecretRequest, arn: str) -> SecretRequest:
        """Set the provisioned ARN on an already-loaded (and locked) request row."""
        request.secret_arn = arn
        self.db.flush()
        return request
