import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, String, UniqueConstraint, func, text
from sqlalchemy import Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.src.models.base import Base

# Valid values as module-level constants so application code and the CHECK
# constraint stay in sync without duplicating the strings.
VALID_ENVIRONMENTS: tuple[str, ...] = ("dev", "staging", "prod")
VALID_STATUSES: tuple[str, ...] = (
    "PENDING",
    "APPROVED",
    "PROVISIONING",
    "PROVISIONED",
    "FAILED",
)

# Environment is stored as VARCHAR with a CHECK constraint rather than a
# PostgreSQL ENUM type. Reason: adding a new environment later only requires
# an ALTER TABLE ... ADD CHECK / DROP CONSTRAINT, while a native ENUM type
# requires ALTER TYPE ... ADD VALUE which cannot be rolled back inside a
# transaction — a critical limitation for zero-downtime migrations on Aurora.
_ENV_CHECK = "environment IN ('dev', 'staging', 'prod')"
_STATUS_CHECK = (
    "status IN ('PENDING', 'APPROVED', 'PROVISIONING', 'PROVISIONED', 'FAILED')"
)


class SecretRequest(Base):
    __tablename__ = "secret_requests"

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True, native_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    service_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True, native_uuid=True),
        ForeignKey("services.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    logical_name: Mapped[str] = mapped_column(String(255), nullable=False)
    environment: Mapped[str] = mapped_column(String(10), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, server_default="PENDING"
    )
    secret_arn: Mapped[str | None] = mapped_column(String(2048), nullable=True)
    description: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=text("now()"),
        onupdate=func.now(),
        nullable=False,
    )

    __table_args__ = (
        CheckConstraint(_ENV_CHECK, name="ck_secret_requests_environment"),
        CheckConstraint(_STATUS_CHECK, name="ck_secret_requests_status"),
        UniqueConstraint(
            "service_id",
            "logical_name",
            "environment",
            name="uq_secret_requests_service_logical_env",
        ),
    )
