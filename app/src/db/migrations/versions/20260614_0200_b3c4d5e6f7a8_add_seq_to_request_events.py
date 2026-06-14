"""add seq to request_events

Revision ID: b3c4d5e6f7a8
Revises: 8f420c53a596
Create Date: 2026-06-14 02:00:00.000000

Adds a BIGINT GENERATED ALWAYS AS IDENTITY column to request_events.
This provides a monotonic per-insert tiebreaker for events that share the same
timestamp (which happens whenever two events are written in the same DB transaction,
because Postgres now() returns the transaction start time for all rows in that tx).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b3c4d5e6f7a8"
down_revision: str | None = "8f420c53a596"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "request_events",
        sa.Column("seq", sa.BigInteger(), sa.Identity(always=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_column("request_events", "seq")
