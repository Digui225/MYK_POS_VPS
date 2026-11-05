"""market_purchase_reception

Revision ID: 028_market_purchase_reception
Revises: 027_cash_regularizations
Create Date: 2026-11-05 10:00:00.000000

Réception des bons d'achat marché (D9) : la validation du bon ne fait plus entrer le stock.
Au retour du marché, un responsable saisit les quantités réellement reçues, qui seules entrent
en stock ; une erreur constatée plus tard se corrige par un mouvement d'achat signé et tracé.

- `market_purchase_items.received_quantity` : quantité reçue (null tant que non réceptionnée) ;
- `market_purchase_lists.received_at` / `received_by_user_id` : auteur de la réception.

Les bons déjà validés (COMPLETED) sont entrés en stock avec les quantités prévues : leur
quantité reçue est initialisée à la quantité prévue, ce qui ne change aucun stock.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "028_market_purchase_reception"
down_revision: Union[str, None] = "027_cash_regularizations"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "market_purchase_items",
        sa.Column("received_quantity", sa.Numeric(12, 3), nullable=True),
    )
    op.add_column(
        "market_purchase_lists",
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "market_purchase_lists",
        sa.Column(
            "received_by_user_id",
            sa.String(length=36),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=True,
        ),
    )
    op.execute(
        """
        UPDATE market_purchase_items AS i
        SET received_quantity = i.quantity
        FROM market_purchase_lists AS l
        WHERE l.id = i.purchase_list_id AND l.status = 'COMPLETED'
        """
    )
    op.execute(
        """
        UPDATE market_purchase_lists
        SET received_at = updated_at, received_by_user_id = validated_by_user_id
        WHERE status = 'COMPLETED'
        """
    )


def downgrade() -> None:
    op.drop_column("market_purchase_lists", "received_by_user_id")
    op.drop_column("market_purchase_lists", "received_at")
    op.drop_column("market_purchase_items", "received_quantity")
