import uuid
from datetime import datetime

# sqlalchemy.Uuid (added in SA 2.0) is used over postgresql.UUID because:
# - `native_uuid=True` (default) maps to the native PostgreSQL UUID type on Aurora,
#   giving efficient storage and indexing without any extra configuration.
# - `as_uuid=True` (default) returns Python uuid.UUID objects rather than strings,
#   keeping the Python layer type-safe without manual conversion.
# - The portable spelling avoids a dialect-specific import for a property that is
#   effectively the same on every database we'll ever target.
from sqlalchemy import DateTime, String, UniqueConstraint, Uuid, text
from sqlalchemy.orm import Mapped, mapped_column

from app.src.models.base import Base


class Service(Base):
    __tablename__ = "services"

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True, native_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    team: Mapped[str] = mapped_column(String(255), nullable=False)
    owner_email: Mapped[str] = mapped_column(String(320), nullable=False)
    repo_url: Mapped[str | None] = mapped_column(String(2048), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )

    __table_args__ = (UniqueConstraint("name", name="uq_services_name"),)
