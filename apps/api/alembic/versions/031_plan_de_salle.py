"""plan_de_salle

Revision ID: 031_plan_de_salle
Revises: 030_salle_commande
Create Date: 2026-11-06 18:00:00.000000

Écran serveur, lot 3 : plan de salle réel.

Chaque table reçoit sa place sur le plan de sa zone, une grille de 12 colonnes :
- `plan_x`, `plan_y` : case haut-gauche (nulles tant que la table n'est pas placée) ;
- `plan_w`, `plan_h` : taille en cases (2 × 2 par défaut) ;
- `shape` : ROUND ou RECT.

Aucune table existante n'est placée par la migration : l'administration les dispose dans
l'éditeur, et les écrans rangent automatiquement les tables non placées en attendant.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "031_plan_de_salle"
down_revision: Union[str, None] = "030_salle_commande"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("restaurant_tables", sa.Column("plan_x", sa.Integer(), nullable=True))
    op.add_column("restaurant_tables", sa.Column("plan_y", sa.Integer(), nullable=True))
    op.add_column(
        "restaurant_tables",
        sa.Column("plan_w", sa.Integer(), nullable=False, server_default="2"),
    )
    op.add_column(
        "restaurant_tables",
        sa.Column("plan_h", sa.Integer(), nullable=False, server_default="2"),
    )
    op.add_column(
        "restaurant_tables",
        sa.Column("shape", sa.String(length=10), nullable=False, server_default="RECT"),
    )


def downgrade() -> None:
    for column in ("shape", "plan_h", "plan_w", "plan_y", "plan_x"):
        op.drop_column("restaurant_tables", column)
