import uuid
from datetime import datetime

from pydantic import BaseModel


class ServiceCreate(BaseModel):
    name: str
    team: str
    owner_email: str
    repo_url: str | None = None


class ServiceRead(BaseModel):
    id: uuid.UUID
    name: str
    team: str
    owner_email: str
    repo_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}
