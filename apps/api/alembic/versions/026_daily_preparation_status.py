"""daily_preparation_status

Revision ID: 026_daily_preparation_status
Revises: 025_sync_protein_stock
Create Date: 2026-11-04 12:00:00.000000

Règle universelle du stock (D6) : la sortie cuisine devient un contrôle avec un état.
- ESTIMATED : pré-remplie à la clôture de caisse d'après les ventes, à valider ;
- VALIDATED : confirmée par la cuisine ;
- ADJUSTED  : corrigée par la cuisine.
Changement de structure uniquement : aucun stock n'est modifié. Les sorties existantes
créées par la clôture (« Auto-validé à la clôture de caisse ») passent à ESTIMATED ;
les sorties saisies à la main passent à VALIDATED.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "026_daily_preparation_status"
down_revision: Union[str, None] = "025_sync_protein_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "daily_preparations",
        sa.Column(
            "status", sa.String(length=16), nullable=False, server_default=sa.text("'VALIDATED'")
        ),
    )
    op.add_column(
        "daily_preparations",
        sa.Column("estimated_quantity", sa.Numeric(12, 3), nullable=True),
    )
    op.execute(
        "UPDATE daily_preparations "
        "SET status = 'ESTIMATED', estimated_quantity = prepared_quantity "
        "WHERE notes LIKE 'Auto-valid%'"
    )
    op.create_check_constraint(
        "ck_daily_prep_status",
        "daily_preparations",
        "status IN ('ESTIMATED', 'VALIDATED', 'ADJUSTED')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_daily_prep_status", "daily_preparations", type_="check")
    op.drop_column("daily_preparations", "estimated_quantity")
    op.drop_column("daily_preparations", "status")
