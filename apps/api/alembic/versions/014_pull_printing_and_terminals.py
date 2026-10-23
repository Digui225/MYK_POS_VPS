"""pull_printing_and_terminals

Revision ID: 014_pull_printing_and_terminals
Revises: 013_market_purchases_prep
Create Date: 2026-10-22 15:00:00.000000
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "014_pull_printing_and_terminals"
down_revision: Union[str, None] = "013_market_purchases_prep"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    # 1. Table print_terminals
    if "print_terminals" not in tables:
        op.create_table(
            "print_terminals",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("name", sa.String(length=60), nullable=False, unique=True),
            sa.Column("token_hash", sa.String(length=64), nullable=False, unique=True),
            sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("printer_status", sa.JSON(), nullable=False, server_default="{}"),
            sa.Column("created_by", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        )

    # 2. Add columns to print_jobs
    if "print_jobs" in tables:
        columns = [c["name"] for c in insp.get_columns("print_jobs")]
        if "claimed_at" not in columns:
            op.add_column("print_jobs", sa.Column("claimed_at", sa.DateTime(timezone=True), nullable=True))
        if "terminal_id" not in columns:
            op.add_column("print_jobs", sa.Column("terminal_id", sa.String(length=36), sa.ForeignKey("print_terminals.id", ondelete="SET NULL"), nullable=True))
        if "attempts" not in columns:
            op.add_column("print_jobs", sa.Column("attempts", sa.Integer(), server_default="0", nullable=False))


def downgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    if "print_jobs" in tables:
        columns = [c["name"] for c in insp.get_columns("print_jobs")]
        if "attempts" in columns:
            op.drop_column("print_jobs", "attempts")
        if "terminal_id" in columns:
            op.drop_column("print_jobs", "terminal_id")
        if "claimed_at" in columns:
            op.drop_column("print_jobs", "claimed_at")

    if "print_terminals" in tables:
        op.drop_table("print_terminals")
