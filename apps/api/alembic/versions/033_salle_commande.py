"""salle_commande

Revision ID: 033_salle_commande
Revises: 032_date_entree_stock
Create Date: 2026-11-06 16:00:00.000000

Écran serveur, lot 2 : prise de commande en salle et envoi en cuisine.

- `orders.service_mode` (SUR_PLACE, EMPORTER, LIVRAISON) vient de la migration 030, passée
  avant sur `aziz` avec la livraison à la caisse (D12).
- `orders.served_by_user_id` : serveur de la note (nul pour une commande prise à la caisse).
- `orders.dispatch_count` : nombre d'envois en cuisine ; `orders.bill_requested_at` : demande
  d'addition du serveur.
- `order_items.seat` (0 = table, 1..n = convive) et `order_items.dispatch_no` (envoi d'origine).
- `payments.handed_by_user_id` : serveur qui a rapporté l'argent.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "033_salle_commande"
down_revision: Union[str, None] = "032_date_entree_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "orders",
        sa.Column(
            "served_by_user_id",
            sa.String(length=36),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=True,
        ),
    )
    op.add_column(
        "orders",
        sa.Column("dispatch_count", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column(
        "orders",
        sa.Column("bill_requested_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column("order_items", sa.Column("seat", sa.Integer(), nullable=True))
    op.add_column("order_items", sa.Column("dispatch_no", sa.Integer(), nullable=True))
    op.add_column(
        "payments",
        sa.Column(
            "handed_by_user_id",
            sa.String(length=36),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("payments", "handed_by_user_id")
    op.drop_column("order_items", "dispatch_no")
    op.drop_column("order_items", "seat")
    op.drop_column("orders", "bill_requested_at")
    op.drop_column("orders", "dispatch_count")
    op.drop_column("orders", "served_by_user_id")
