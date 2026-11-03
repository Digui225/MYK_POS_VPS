"""add_include_condiments_envelope_to_market_purchase_lists

Revision ID: 022_add_condiments_envelope
Revises: 021_rename_brochet_and_saumon
Create Date: 2026-11-03 01:10:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "022_add_condiments_envelope"
down_revision: Union[str, None] = "021_rename_brochet_and_saumon"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "market_purchase_lists",
        sa.Column(
            "include_condiments_envelope",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column("market_purchase_lists", "include_condiments_envelope")
