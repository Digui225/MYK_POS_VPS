"""expenses_and_bank_deposits

Revision ID: 012_expenses_and_bank_deposits
Revises: 011_stock_articles_recipes
Create Date: 2026-10-21 14:30:00.000000
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "012_expenses_and_bank_deposits"
down_revision: Union[str, None] = "011_stock_articles_recipes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    # 1. Créer cash_expenses
    if "cash_expenses" not in tables:
        op.create_table(
            "cash_expenses",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("business_date", sa.Date(), nullable=False, index=True),
            sa.Column("cash_session_id", sa.String(length=36), sa.ForeignKey("cash_sessions.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("category", sa.String(length=50), nullable=False),
            sa.Column("amount_xof", sa.Integer(), nullable=False),
            sa.Column("recipient", sa.String(length=100), nullable=True),
            sa.Column("reason", sa.String(length=255), nullable=False),
            sa.Column("receipt_reference", sa.String(length=100), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.CheckConstraint("amount_xof > 0", name="ck_cash_expenses_amount_positive"),
        )

    # 2. Créer bank_deposits
    if "bank_deposits" not in tables:
        op.create_table(
            "bank_deposits",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("business_date", sa.Date(), nullable=False, index=True),
            sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("amount_xof", sa.Integer(), nullable=False),
            sa.Column("bank_name", sa.String(length=100), nullable=False),
            sa.Column("slip_number", sa.String(length=100), nullable=False),
            sa.Column("deposited_by", sa.String(length=100), nullable=True),
            sa.Column("notes", sa.String(length=255), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.CheckConstraint("amount_xof > 0", name="ck_bank_deposits_amount_positive"),
        )


def downgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    if "bank_deposits" in tables:
        op.drop_table("bank_deposits")
    if "cash_expenses" in tables:
        op.drop_table("cash_expenses")
