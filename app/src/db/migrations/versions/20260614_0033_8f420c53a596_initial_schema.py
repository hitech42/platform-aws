"""initial schema

Revision ID: 8f420c53a596
Revises:
Create Date: 2026-06-14 00:33:30.369858

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "8f420c53a596"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "services",
        sa.Column(
            "id",
            sa.Uuid(),
            # gen_random_uuid() is the DB-level fallback for direct SQL inserts;
            # the ORM uses uuid.uuid4() via the Python-side column default.
            server_default=sa.text("gen_random_uuid()"),
            nullable=False,
        ),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("team", sa.String(length=255), nullable=False),
        sa.Column("owner_email", sa.String(length=320), nullable=False),
        sa.Column("repo_url", sa.String(length=2048), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name", name="uq_services_name"),
    )
    op.create_table(
        "secret_requests",
        sa.Column(
            "id",
            sa.Uuid(),
            server_default=sa.text("gen_random_uuid()"),
            nullable=False,
        ),
        sa.Column("service_id", sa.Uuid(), nullable=False),
        sa.Column("logical_name", sa.String(length=255), nullable=False),
        sa.Column("environment", sa.String(length=10), nullable=False),
        sa.Column("status", sa.String(length=20), server_default="PENDING", nullable=False),
        sa.Column("secret_arn", sa.String(length=2048), nullable=True),
        sa.Column("description", sa.String(length=1000), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "environment IN ('dev', 'staging', 'prod')",
            name="ck_secret_requests_environment",
        ),
        sa.CheckConstraint(
            "status IN ('PENDING', 'APPROVED', 'PROVISIONING', 'PROVISIONED', 'FAILED')",
            name="ck_secret_requests_status",
        ),
        sa.ForeignKeyConstraint(["service_id"], ["services.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "service_id",
            "logical_name",
            "environment",
            name="uq_secret_requests_service_logical_env",
        ),
    )
    op.create_index(
        op.f("ix_secret_requests_service_id"),
        "secret_requests",
        ["service_id"],
        unique=False,
    )
    op.create_table(
        "request_events",
        sa.Column(
            "id",
            sa.Uuid(),
            server_default=sa.text("gen_random_uuid()"),
            nullable=False,
        ),
        sa.Column("secret_request_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.String(length=20), nullable=False),
        sa.Column("actor", sa.String(length=320), nullable=False),
        sa.Column("detail", sa.String(length=2000), nullable=True),
        sa.Column(
            "timestamp",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["secret_request_id"], ["secret_requests.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_request_events_secret_request_id"),
        "request_events",
        ["secret_request_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_request_events_secret_request_id"), table_name="request_events")
    op.drop_table("request_events")
    op.drop_index(op.f("ix_secret_requests_service_id"), table_name="secret_requests")
    op.drop_table("secret_requests")
    op.drop_table("services")
