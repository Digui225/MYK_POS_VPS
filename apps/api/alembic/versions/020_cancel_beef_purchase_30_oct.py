"""cancel_beef_purchase_30_oct

Revision ID: 020_cancel_beef_purchase_30_oct
Revises: 019_clean_duplicate_sauces
Create Date: 2026-11-02 18:30:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "020_cancel_beef_purchase_30_oct"
down_revision: Union[str, None] = "019_clean_duplicate_sauces"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # 1. Identifier l'article Bœuf (catégorie PROTEINE)
    beef_row = bind.execute(
        sa.text(
            "SELECT id, quantity FROM stock_articles "
            "WHERE (name ILIKE 'b_uf' OR name ILIKE '%b_uf%') AND category = 'PROTEINE' "
            "ORDER BY CASE WHEN name ILIKE 'b_uf' THEN 0 ELSE 1 END LIMIT 1"
        )
    ).fetchone()

    if not beef_row:
        return

    beef_id = beef_row[0]

    # 2. Trouver le bon d'achat marché du 30 octobre 2026
    purchase_row = bind.execute(
        sa.text(
            "SELECT id, total_budget_xof, notes FROM market_purchase_lists "
            "WHERE business_date = '2026-10-30'"
        )
    ).fetchone()

    if not purchase_row:
        return

    purchase_id = purchase_row[0]
    total_budget = purchase_row[1] or 0
    notes = purchase_row[2] or ""

    # 3. Trouver la ligne Bœuf sur ce bon d'achat
    item_row = bind.execute(
        sa.text(
            "SELECT id, quantity, total_price_xof FROM market_purchase_items "
            "WHERE purchase_list_id = :pid AND article_id = :aid"
        ),
        {"pid": purchase_id, "aid": beef_id},
    ).fetchone()

    if not item_row:
        return

    item_id = item_row[0]
    item_qty = float(item_row[1])
    item_price = int(item_row[2])

    # 4. Supprimer la ligne de bœuf sur le bon d'achat
    bind.execute(
        sa.text("DELETE FROM market_purchase_items WHERE id = :item_id"),
        {"item_id": item_id},
    )

    # 5. Mettre à jour le montant total et les notes du bon d'achat
    new_budget = max(0, total_budget - item_price)
    note_suffix = f" (Bœuf {item_qty:g}kg retiré car non acheté)"
    new_notes = notes + note_suffix if note_suffix not in notes else notes
    bind.execute(
        sa.text(
            "UPDATE market_purchase_lists "
            "SET total_budget_xof = :nb, notes = :notes "
            "WHERE id = :pid"
        ),
        {"nb": new_budget, "notes": new_notes, "pid": purchase_id},
    )

    # 6. Déduire la quantité exacte du stock physique actuel (sans passer sous zéro)
    bind.execute(
        sa.text(
            "UPDATE stock_articles "
            "SET quantity = GREATEST(0, quantity - :qty) "
            "WHERE id = :aid"
        ),
        {"qty": item_qty, "aid": beef_id},
    )

    # 7. Supprimer le mouvement de stock d'entrée PURCHASE_IN correspondant du 30/10
    bind.execute(
        sa.text(
            "DELETE FROM stock_movements "
            "WHERE article_id = :aid "
            "  AND type = 'PURCHASE_IN' "
            "  AND business_date = '2026-10-30' "
            "  AND quantity = :qty"
        ),
        {"aid": beef_id, "qty": item_qty},
    )

    # 8. Réajuster la dépense de caisse MARCHE_APPOINT du 30/10 si elle a été générée
    bind.execute(
        sa.text(
            "UPDATE cash_expenses "
            "SET amount_xof = GREATEST(0, amount_xof - :price), "
            "    reason = reason || ' [Bœuf déduit]' "
            "WHERE business_date = '2026-10-30' "
            "  AND category = 'MARCHE_APPOINT'"
        ),
        {"price": item_price},
    )


def downgrade() -> None:
    pass
