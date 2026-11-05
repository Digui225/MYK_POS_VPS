"""market_purchase_cancel

Revision ID: 029_market_purchase_cancel
Revises: 028_market_purchase_reception
Create Date: 2026-11-05 19:00:00.000000

Annulation des bons d'achat marché (D10) : un bon pas encore validé (DRAFT) peut être annulé
par le responsable, l'admin ou l'économe qui l'a préparé, avec un motif obligatoire. Le bon
n'est jamais supprimé : il passe à CANCELLED et reste dans l'historique.

- `market_purchase_lists.cancelled_at` / `cancelled_by_user_id` / `cancel_reason`.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "029_market_purchase_cancel"
down_revision: Union[str, None] = "028_market_purchase_reception"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "market_purchase_lists",
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "market_purchase_lists",
        sa.Column(
            "cancelled_by_user_id",
            sa.String(length=36),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=True,
        ),
    )
    op.add_column(
        "market_purchase_lists",
        sa.Column("cancel_reason", sa.String(length=255), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("market_purchase_lists", "cancel_reason")
    op.drop_column("market_purchase_lists", "cancelled_by_user_id")
    op.drop_column("market_purchase_lists", "cancelled_at")
