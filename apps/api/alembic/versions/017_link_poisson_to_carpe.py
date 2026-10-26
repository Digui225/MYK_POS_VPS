"""link_poisson_to_carpe

Revision ID: 017_link_poisson_to_carpe
Revises: 016_auto_recipes_for_9_proteins
Create Date: 2026-10-26 16:22:00.000000
"""

from decimal import Decimal
from typing import Sequence, Union
import uuid

from alembic import op
import sqlalchemy as sa


revision: str = "017_link_poisson_to_carpe"
down_revision: Union[str, None] = "016_auto_recipes_for_9_proteins"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # 1. Récupérer l'ID de l'article Carpe
    carpe_row = bind.execute(
        sa.text("SELECT id FROM stock_articles WHERE name = 'Carpe' AND category = 'PROTEINE'")
    ).fetchone()
    if not carpe_row:
        return
    carpe_id = str(carpe_row[0])

    # 2. Récupérer les produits contenant 'poisson' ou 'poisson braisé' (hors poisson fumé)
    products_res = bind.execute(
        sa.text("""
            SELECT id, name
            FROM products
            WHERE is_custom = false
              AND (name ILIKE '%poisson%' OR short_name ILIKE '%pois.br%' OR short_name ILIKE '%pois.brais%')
              AND name NOT ILIKE '%fumé%'
              AND name NOT ILIKE '%fume%'
        """)
    ).fetchall()

    # 3. Récupérer les fiches déjà existantes
    comps_res = bind.execute(
        sa.text("SELECT product_id, article_id FROM product_components")
    ).fetchall()
    existing_comps = set((str(r[0]), str(r[1])) for r in comps_res)

    insert_rows = []
    for pid, pname in products_res:
        if (str(pid), carpe_id) not in existing_comps:
            comp_id = str(uuid.uuid4())
            insert_rows.append(
                {
                    "id": comp_id,
                    "product_id": str(pid),
                    "article_id": carpe_id,
                    "quantity": Decimal("1.000"),
                }
            )
            existing_comps.add((str(pid), carpe_id))

    if insert_rows:
        components_table = sa.table(
            "product_components",
            sa.column("id", sa.String),
            sa.column("product_id", sa.String),
            sa.column("article_id", sa.String),
            sa.column("quantity", sa.Numeric),
        )
        op.bulk_insert(components_table, insert_rows)


def downgrade() -> None:
    pass
