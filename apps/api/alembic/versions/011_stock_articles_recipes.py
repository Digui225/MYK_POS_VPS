"""stock_articles_and_fiches_techniques

Revision ID: 011_stock_articles_and_fiches_techniques
Revises: 010_drop_uq_active_order_table
Create Date: 2026-10-20 15:00:00.000000
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa


revision: str = "011_stock_articles_recipes"
down_revision: Union[str, None] = "010_drop_uq_active_order_table"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    tables = insp.get_table_names()

    # 1. Créer stock_articles
    if "stock_articles" not in tables:
        op.create_table(
            "stock_articles",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("name", sa.String(length=120), unique=True, nullable=False),
            sa.Column("category", sa.String(length=32), nullable=False),
            sa.Column("unit", sa.String(length=16), nullable=False),
            sa.Column("out_mode", sa.String(length=32), nullable=False),
            sa.Column("quantity", sa.Numeric(precision=12, scale=3), server_default="0", nullable=False),
            sa.Column("avg_cost_xof", sa.Numeric(precision=12, scale=2), server_default="0", nullable=False),
            sa.Column("alert_threshold", sa.Numeric(precision=12, scale=3), nullable=True),
            sa.Column("is_active", sa.Boolean(), server_default="1", nullable=False),
            sa.Column("note", sa.String(length=255), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
            sa.CheckConstraint("avg_cost_xof >= 0", name="ck_stock_articles_avg_cost_positive"),
        )

    # 2. Créer product_components (fiches techniques)
    if "product_components" not in tables:
        op.create_table(
            "product_components",
            sa.Column("id", sa.String(length=36), primary_key=True),
            sa.Column("product_id", sa.String(length=36), sa.ForeignKey("products.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("article_id", sa.String(length=36), sa.ForeignKey("stock_articles.id", ondelete="RESTRICT"), nullable=False),
            sa.Column("quantity", sa.Numeric(precision=12, scale=3), nullable=False),
            sa.UniqueConstraint("product_id", "article_id", name="uq_product_components_product_article"),
            sa.CheckConstraint("quantity > 0", name="ck_product_components_quantity_positive"),
        )
        op.create_index("ix_product_components_product_id", "product_components", ["product_id"])
        op.create_index("ix_product_components_article_id", "product_components", ["article_id"])

    # 3. Mettre à niveau stock_movements
    if "stock_movements" in tables:
        # Supprimer l'ancienne table de test/dev et recréer la structure propre
        op.drop_table("stock_movements")

    op.create_table(
        "stock_movements",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("article_id", sa.String(length=36), sa.ForeignKey("stock_articles.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("type", sa.String(length=32), nullable=False),
        sa.Column("quantity", sa.Numeric(precision=12, scale=3), nullable=False),
        sa.Column("quantity_after", sa.Numeric(precision=12, scale=3), nullable=False),
        sa.Column("unit_cost_xof", sa.Numeric(precision=12, scale=2), nullable=False),
        sa.Column("business_date", sa.Date(), nullable=False),
        sa.Column("reference_order_id", sa.String(length=36), sa.ForeignKey("orders.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("reference_order_item_id", sa.String(length=36), sa.ForeignKey("order_items.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("supplier", sa.String(length=120), nullable=True),
        sa.Column("reason", sa.String(length=255), nullable=True),
        sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_stock_movements_article_id", "stock_movements", ["article_id"])
    op.create_index("ix_stock_movements_business_date", "stock_movements", ["business_date"])
    op.create_index("ix_stock_movements_reference_order_id", "stock_movements", ["reference_order_id"])


def downgrade() -> None:
    op.drop_table("stock_movements")
    op.drop_table("product_components")
    op.drop_table("stock_articles")
