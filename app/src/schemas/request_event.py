import uuid
from datetime import datetime

from pydantic import BaseModel


class RequestEventCreate(BaseModel):
    secret_request_id: uuid.UUID
    status: str
    actor: str
    detail: str | None = None


class RequestEventRead(BaseModel):
    id: uuid.UUID
    secret_request_id: uuid.UUID
    status: str
    actor: str
    detail: str | None
    timestamp: datetime

    model_config = {"from_attributes": True}
