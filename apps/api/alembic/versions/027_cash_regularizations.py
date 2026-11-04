"""cash_regularizations

Revision ID: 027_cash_regularizations
Revises: 026_daily_preparation_status
Create Date: 2026-11-04 19:00:00.000000

Régularisation d'un écart de caisse après la clôture : le Z clôturé ne change pas, une
opération tracée (montant signé, motif, auteur) est enregistrée à côté, datée du jour de
l'écart. Nouvelle table uniquement : aucune donnée existante n'est modifiée.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "027_cash_regularizations"
down_revision: Union[str, None] = "026_daily_preparation_status"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "cash_regularizations",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("business_date", sa.Date(), nullable=False),
        sa.Column(
            "cash_session_id", sa.String(length=36), sa.ForeignKey("cash_sessions.id"), nullable=False
        ),
        sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("amount_xof", sa.Integer(), nullable=False),
        sa.Column("reason", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("amount_xof <> 0", name="ck_cash_regularization_amount"),
    )
    op.create_index(
        "ix_cash_regularizations_business_date", "cash_regularizations", ["business_date"]
    )
    op.create_index(
        "ix_cash_regularizations_cash_session_id", "cash_regularizations", ["cash_session_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_cash_regularizations_cash_session_id", table_name="cash_regularizations")
    op.drop_index("ix_cash_regularizations_business_date", table_name="cash_regularizations")
    op.drop_table("cash_regularizations")
