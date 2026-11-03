"""rename_brochet_and_saumon

Revision ID: 021_rename_brochet_and_saumon
Revises: 020_cancel_beef_purchase_30_oct
Create Date: 2026-11-03 00:35:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "021_rename_brochet_and_saumon"
down_revision: Union[str, None] = "020_cancel_beef_purchase_30_oct"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # 1. Renommer les articles de stock (catégorie PROTEINE)
    # Faux brochet -> Brochet
    bind.execute(
        sa.text(
            "UPDATE stock_articles "
            "SET name = 'Brochet' "
            "WHERE (name ILIKE 'faux brochet' OR name ILIKE '%faux brochet%') "
            "AND category = 'PROTEINE'"
        )
    )
    # Faux saumon -> Saumon
    bind.execute(
        sa.text(
            "UPDATE stock_articles "
            "SET name = 'Saumon' "
            "WHERE (name ILIKE 'faux saumon' OR name ILIKE '%faux saumon%') "
            "AND category = 'PROTEINE'"
        )
    )

    # 2. Renommer les produits du catalogue
    # 'Plat faux brochet' -> 'Plat brochet'
    bind.execute(
        sa.text(
            "UPDATE products "
            "SET name = 'Plat brochet', short_name = 'Plat brochet' "
            "WHERE name ILIKE 'plat faux brochet' OR short_name ILIKE 'plat faux brochet'"
        )
    )
    # 'Foufou/foutou faux brochet' -> 'Foufou/foutou brochet'
    bind.execute(
        sa.text(
            "UPDATE products "
            "SET name = 'Foufou/foutou brochet', short_name = 'Foufou brochet' "
            "WHERE name ILIKE 'foufou/foutou faux brochet' OR short_name ILIKE 'foufou faux brochet'"
        )
    )
    # 'Faux saumon' -> 'Saumon'
    bind.execute(
        sa.text(
            "UPDATE products "
            "SET name = 'Saumon', short_name = 'Saumon' "
            "WHERE name ILIKE 'faux saumon' OR short_name ILIKE 'faux saumon'"
        )
    )
    # Tout autre produit contenant 'faux brochet' ou 'faux saumon'
    bind.execute(
        sa.text(
            "UPDATE products "
            "SET name = REPLACE(REPLACE(name, 'Faux brochet', 'Brochet'), 'faux brochet', 'brochet'), "
            "    short_name = REPLACE(REPLACE(short_name, 'Faux brochet', 'Brochet'), 'faux brochet', 'brochet') "
            "WHERE name ILIKE '%faux brochet%' OR short_name ILIKE '%faux brochet%'"
        )
    )
    bind.execute(
        sa.text(
            "UPDATE products "
            "SET name = REPLACE(REPLACE(name, 'Faux saumon', 'Saumon'), 'faux saumon', 'saumon'), "
            "    short_name = REPLACE(REPLACE(short_name, 'Faux saumon', 'Saumon'), 'faux saumon', 'saumon') "
            "WHERE name ILIKE '%faux saumon%' OR short_name ILIKE '%faux saumon%'"
        )
    )


def downgrade() -> None:
    bind = op.get_bind()

    # Rétablir les noms initiaux
    bind.execute(
        sa.text(
            "UPDATE stock_articles SET name = 'Faux brochet' WHERE name = 'Brochet' AND category = 'PROTEINE'"
        )
    )
    bind.execute(
        sa.text(
            "UPDATE stock_articles SET name = 'Faux saumon' WHERE name = 'Saumon' AND category = 'PROTEINE'"
        )
    )
    bind.execute(
        sa.text(
            "UPDATE products SET name = 'Plat faux brochet', short_name = 'Plat faux brochet' WHERE name = 'Plat brochet'"
        )
    )
    bind.execute(
        sa.text(
            "UPDATE products SET name = 'Foufou/foutou faux brochet', short_name = 'Foufou faux brochet' WHERE name = 'Foufou/foutou brochet'"
        )
    )
    bind.execute(
        sa.text(
            "UPDATE products SET name = 'Faux saumon', short_name = 'Faux saumon' WHERE name = 'Saumon'"
        )
    )
