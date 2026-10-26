"""auto_recipes_for_9_proteins

Revision ID: 016_auto_recipes_for_9_proteins
Revises: 015_purchase_requests_and_seq
Create Date: 2026-10-26 15:50:00.000000
"""

from decimal import Decimal
from typing import Sequence, Union
import uuid

from alembic import op
import sqlalchemy as sa


revision: str = "016_auto_recipes_for_9_proteins"
down_revision: Union[str, None] = "015_purchase_requests_and_seq"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # 1. Charger les IDs des articles de stock pour chaque protéine
    articles_res = bind.execute(
        sa.text("SELECT id, name FROM stock_articles WHERE category = 'PROTEINE'")
    ).fetchall()
    article_map = {row[1]: str(row[0]) for row in articles_res}

    # 2. Charger les produits actifs
    products_res = bind.execute(
        sa.text("SELECT id, name FROM products WHERE is_custom = false")
    ).fetchall()

    # 3. Charger les fiches déjà existantes (product_id, article_id)
    comps_res = bind.execute(
        sa.text("SELECT product_id, article_id FROM product_components")
    ).fetchall()
    existing_comps = set((str(r[0]), str(r[1])) for r in comps_res)

    # 4. Fonction de matching des 9 protéines
    def match_prot(pname: str) -> tuple[str, Decimal] | None:
        norm = pname.strip().lower()
        if "boeuf" in norm or "bœuf" in norm:
            return ("Bœuf", Decimal("0.200"))
        if "mouton" in norm:
            return ("Mouton", Decimal("0.286"))
        if "pondeuse" in norm or "kedjenou" in norm:
            return ("Poulet pondeuse", Decimal("0.250"))
        if "poulet" in norm:
            return ("Poulet", Decimal("0.250"))
        if "sosso" in norm:
            return ("Sosso", Decimal("1.000"))
        if "carpe" in norm:
            return ("Carpe", Decimal("1.000"))
        if "brochet" in norm:
            return ("Faux brochet", Decimal("1.000"))
        if "loss" in norm:
            return ("Loss", Decimal("1.000"))
        if "saumon" in norm:
            return ("Faux saumon", Decimal("1.000"))
        return None

    # 5. Insérer les fiches manquantes
    insert_rows = []
    for pid, pname in products_res:
        matched = match_prot(pname)
        if not matched:
            continue
        art_name, qty = matched
        art_id = article_map.get(art_name)
        if not art_id:
            # Compatibilité orthographique Bœuf / Boeuf
            if art_name == "Bœuf":
                art_id = article_map.get("Boeuf")
            elif art_name == "Boeuf":
                art_id = article_map.get("Bœuf")
        if not art_id:
            continue

        if (str(pid), str(art_id)) not in existing_comps:
            comp_id = str(uuid.uuid4())
            insert_rows.append(
                {
                    "id": comp_id,
                    "product_id": str(pid),
                    "article_id": str(art_id),
                    "quantity": qty,
                }
            )
            existing_comps.add((str(pid), str(art_id)))

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
