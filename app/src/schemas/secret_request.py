import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel

Environment = Literal["dev", "staging", "prod"]
RequestStatus = Literal["PENDING", "APPROVED", "PROVISIONING", "PROVISIONED", "FAILED"]


class SecretRequestCreate(BaseModel):
    service_id: uuid.UUID
    logical_name: str
    environment: Environment
    description: str | None = None


class SecretRequestRead(BaseModel):
    id: uuid.UUID
    service_id: uuid.UUID
    logical_name: str
    environment: Environment
    status: RequestStatus
    secret_arn: str | None
    description: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
