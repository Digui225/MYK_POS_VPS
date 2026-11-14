"""date_entree_stock

Revision ID: 032_date_entree_stock
Revises: 031_masquer_anciens_menus
Create Date: 2026-11-09 19:00:00.000000

Date d'entrée en stock des bons d'achat marché (D13) : les achats reçus entrent en stock au jour
de la réception, plus à la date du bon (un bon se prépare souvent la veille du marché).

- `market_purchase_lists.stock_date` : date des mouvements de stock du bon.
- Les bons déjà réceptionnés gardent la règle d'avant (D9) : leur stock est entré à la date du
  bon, `stock_date` = `business_date`. Aucun mouvement de stock n'est touché.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "032_date_entree_stock"
down_revision: Union[str, None] = "031_masquer_anciens_menus"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("market_purchase_lists", sa.Column("stock_date", sa.Date(), nullable=True))
    op.execute(
        "UPDATE market_purchase_lists SET stock_date = business_date WHERE status = 'COMPLETED'"
    )


def downgrade() -> None:
    op.drop_column("market_purchase_lists", "stock_date")
