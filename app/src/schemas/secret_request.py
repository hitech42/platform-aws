import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field

Environment = Literal["dev", "staging", "prod"]
RequestStatus = Literal["PENDING", "APPROVED", "PROVISIONING", "PROVISIONED", "FAILED"]


# ── API request bodies ──────────────────────────────────────────────────────────


class SecretRequestBody(BaseModel):
    """Body for POST /services/{service_id}/secret-requests.

    service_id is deliberately absent here — it comes from the URL path so the
    consumer cannot accidentally submit a mismatched ID in the body.
    """

    logical_name: str = Field(min_length=1, max_length=100)
    environment: Environment
    # generate_value=True means the platform generates a random secret value.
    # Accepting a caller-supplied value is a future consideration (see DECISIONS.md).
    generate_value: bool
    description: str | None = Field(default=None, max_length=500)
    # Placeholder for real authentication; will be replaced by JWT claims in a future session.
    requested_by: str | None = None


class ApproveRequest(BaseModel):
    approver_email: EmailStr


# ── DB-level / internal schemas (also used directly in session-2 tests) ─────────


class SecretRequestCreate(BaseModel):
    """Internal schema used when constructing a SecretRequest ORM object.
    service_id is included here because the service layer receives it separately
    from the API path and combines it with the body before writing to the DB.
    """

    service_id: uuid.UUID
    logical_name: str = Field(min_length=1, max_length=100)
    environment: Environment
    description: str | None = Field(default=None, max_length=500)


# ── Response schemas ────────────────────────────────────────────────────────────


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


class RequestEventRead(BaseModel):
    id: uuid.UUID
    secret_request_id: uuid.UUID
    status: RequestStatus
    actor: str
    detail: str | None
    timestamp: datetime

    model_config = {"from_attributes": True}
