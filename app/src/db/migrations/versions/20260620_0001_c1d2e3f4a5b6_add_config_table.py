"""add config table with llm_provider seed

Revision ID: c1d2e3f4a5b6
Revises: b3c4d5e6f7a8
Create Date: 2026-06-20 00:01:00.000000

Adds a key/value config table for runtime-tunable settings.
Seed: llm_provider = 'anthropic_api' (default while Bedrock account quota is
blocked; switch to 'bedrock' once the AWS support case resolves quota).

updated_at mirrors the pattern on secret_requests: server default now(), ORM-level
onupdate=func.now() keeps it current on every ORM UPDATE.  Direct psql UPDATEs will
not auto-refresh updated_at — that is acceptable for an ops-level config change.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c1d2e3f4a5b6"
down_revision: str | None = "b3c4d5e6f7a8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    config_table = op.create_table(
        "config",
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("key"),
    )
    op.bulk_insert(
        config_table,
        [{"key": "llm_provider", "value": "anthropic_api"}],
    )


def downgrade() -> None:
    op.drop_table("config")
