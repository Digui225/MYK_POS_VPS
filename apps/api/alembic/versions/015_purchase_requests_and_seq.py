"""purchase_requests_and_sequences

Revision ID: 015_purchase_requests_and_sequences
Revises: 014_pull_printing_and_terminals
Create Date: 2026-10-22 15:40:00.000000
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "015_purchase_requests_and_seq"
down_revision: Union[str, None] = "014_pull_printing_and_terminals"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    # 1. sequence_counters
    if "sequence_counters" not in tables:
        op.create_table(
            "sequence_counters",
            sa.Column("key", sa.String(length=80), primary_key=True),
            sa.Column("value", sa.Integer(), nullable=False, server_default="0"),
        )

    # 2. purchase_requests
    if "purchase_requests" not in tables:
        op.create_table(
            "purchase_requests",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("number", sa.String(length=16), unique=True, nullable=False),
            sa.Column("status", sa.String(length=32), index=True, nullable=False, server_default="SUBMITTED"),
            sa.Column("requested_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), index=True, nullable=False),
            sa.Column("note", sa.String(length=255), nullable=True),
            sa.Column("estimated_total_xof", sa.Integer(), nullable=False),
            sa.Column("approved_total_xof", sa.Integer(), nullable=True),
            sa.Column("approved_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("disbursed_xof", sa.Integer(), nullable=True),
            sa.Column("disbursed_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("disbursed_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("received_total_xof", sa.Integer(), nullable=True),
            sa.Column("received_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("supplier", sa.String(length=120), nullable=True),
            sa.Column("closed_reason", sa.String(length=255), nullable=True),
            sa.Column("closed_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        )

    # 3. purchase_request_lines
    if "purchase_request_lines" not in tables:
        op.create_table(
            "purchase_request_lines",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("request_id", sa.String(length=36), sa.ForeignKey("purchase_requests.id", ondelete="RESTRICT"), index=True, nullable=False),
            sa.Column("article_id", sa.String(length=36), sa.ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False),
            sa.Column("requested_quantity", sa.Numeric(precision=12, scale=3), nullable=False),
            sa.Column("approved_quantity", sa.Numeric(precision=12, scale=3), nullable=True),
            sa.Column("unit_price_xof", sa.Numeric(precision=12, scale=2), nullable=False),
            sa.Column("received_quantity", sa.Numeric(precision=12, scale=3), nullable=True),
            sa.Column("received_cost_xof", sa.Integer(), nullable=True),
            sa.Column("stock_movement_id", sa.String(length=36), sa.ForeignKey("stock_movements.id", ondelete="RESTRICT"), nullable=True),
            sa.UniqueConstraint("request_id", "article_id", name="uq_purchase_request_lines_article"),
            sa.CheckConstraint("requested_quantity > 0", name="ck_purchase_request_lines_requested_quantity_positive"),
        )


def downgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    if "purchase_request_lines" in tables:
        op.drop_table("purchase_request_lines")
    if "purchase_requests" in tables:
        op.drop_table("purchase_requests")
    if "sequence_counters" in tables:
        op.drop_table("sequence_counters")
