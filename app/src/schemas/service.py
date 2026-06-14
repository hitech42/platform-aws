import uuid
from datetime import datetime

from pydantic import BaseModel, EmailStr, Field


class ServiceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    team: str = Field(min_length=1, max_length=100)
    owner_email: EmailStr
    repo_url: str | None = None


class ServiceRead(BaseModel):
    id: uuid.UUID
    name: str
    team: str
    owner_email: str
    repo_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}
