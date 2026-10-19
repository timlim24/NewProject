"""add ai_suggestion column to meetings

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-19
"""

from collections.abc import Sequence
import sqlalchemy as sa
from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("meetings", sa.Column("ai_suggestion", sa.JSON(), nullable=True))


def downgrade() -> None:
    op.drop_column("meetings", "ai_suggestion")
