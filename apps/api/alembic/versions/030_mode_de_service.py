"""mode_de_service

Revision ID: 030_mode_de_service
Revises: 029_market_purchase_cancel
Create Date: 2026-11-08 16:00:00.000000

Livraison à la caisse : `orders.service_mode` vaut SUR_PLACE (table), EMPORTER ou LIVRAISON.
La livraison se prend comme l'emporter (sans table, ni client ni frais) et se compte à part
dans l'historique, le tableau de bord et les rapports. Les commandes existantes sans table
deviennent EMPORTER (c'était le seul cas possible), les autres SUR_PLACE.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "030_mode_de_service"
down_revision: Union[str, None] = "029_market_purchase_cancel"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "orders",
        sa.Column("service_mode", sa.String(length=20), nullable=False, server_default="SUR_PLACE"),
    )
    op.execute("UPDATE orders SET service_mode = 'EMPORTER' WHERE table_id IS NULL")


def downgrade() -> None:
    op.drop_column("orders", "service_mode")
