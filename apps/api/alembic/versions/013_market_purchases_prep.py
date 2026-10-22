"""market_purchases_prep

Revision ID: 013_market_purchases_prep
Revises: 012_expenses_and_bank_deposits
Create Date: 2026-10-21 16:30:00.000000
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "013_market_purchases_prep"
down_revision: Union[str, None] = "012_expenses_and_bank_deposits"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    # 1. market_purchase_lists
    if "market_purchase_lists" not in tables:
        op.create_table(
            "market_purchase_lists",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("business_date", sa.Date(), nullable=False, index=True),
            sa.Column("status", sa.String(length=20), server_default="DRAFT", nullable=False, index=True),
            sa.Column("created_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("validated_by_user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
            sa.Column("total_budget_xof", sa.Integer(), server_default="0", nullable=False),
            sa.Column("notes", sa.String(length=255), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.CheckConstraint("total_budget_xof >= 0", name="ck_market_purchase_lists_budget_positive"),
        )

    # 2. market_purchase_items
    if "market_purchase_items" not in tables:
        op.create_table(
            "market_purchase_items",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("purchase_list_id", sa.String(length=36), sa.ForeignKey("market_purchase_lists.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("article_id", sa.String(length=36), sa.ForeignKey("stock_articles.id", ondelete="RESTRICT"), nullable=False, index=True),
            sa.Column("quantity", sa.Numeric(precision=12, scale=3), nullable=False),
            sa.Column("unit_price_xof", sa.Integer(), nullable=False),
            sa.Column("total_price_xof", sa.Integer(), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.CheckConstraint("quantity > 0", name="ck_market_purchase_items_qty_positive"),
            sa.CheckConstraint("unit_price_xof >= 0", name="ck_market_purchase_items_unit_price_positive"),
            sa.CheckConstraint("total_price_xof >= 0", name="ck_market_purchase_items_total_price_positive"),
        )

    # 3. daily_preparations
    if "daily_preparations" not in tables:
        op.create_table(
            "daily_preparations",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("business_date", sa.Date(), nullable=False, index=True),
            sa.Column("article_id", sa.String(length=36), sa.ForeignKey("stock_articles.id", ondelete="RESTRICT"), nullable=False, index=True),
            sa.Column("prepared_quantity", sa.Numeric(precision=12, scale=3), nullable=False),
            sa.Column("yield_portions_per_unit", sa.Numeric(precision=6, scale=2), nullable=False),
            sa.Column("theoretical_dishes", sa.Integer(), nullable=False),
            sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("notes", sa.String(length=255), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.UniqueConstraint("business_date", "article_id", name="uq_daily_prep_date_article"),
            sa.CheckConstraint("prepared_quantity > 0", name="ck_daily_prep_qty_positive"),
            sa.CheckConstraint("yield_portions_per_unit > 0", name="ck_daily_prep_yield_positive"),
            sa.CheckConstraint("theoretical_dishes >= 0", name="ck_daily_prep_dishes_positive"),
        )


def downgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    if "daily_preparations" in tables:
        op.drop_table("daily_preparations")
    if "market_purchase_items" in tables:
        op.drop_table("market_purchase_items")
    if "market_purchase_lists" in tables:
        op.drop_table("market_purchase_lists")
