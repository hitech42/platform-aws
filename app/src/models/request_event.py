import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, text
from sqlalchemy import Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.src.models.base import Base


class RequestEvent(Base):
    __tablename__ = "request_events"

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True, native_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    secret_request_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True, native_uuid=True),
        ForeignKey("secret_requests.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    actor: Mapped[str] = mapped_column(String(320), nullable=False)
    detail: Mapped[str | None] = mapped_column(String(2000), nullable=True)
    timestamp: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )
