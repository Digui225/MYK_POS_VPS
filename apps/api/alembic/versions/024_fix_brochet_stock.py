"""fix_brochet_stock

Revision ID: 024_fix_brochet_stock
Revises: 023_rename_bro_products
Create Date: 2026-11-03 19:42:00.000000
"""

import re
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "024_fix_brochet_stock"
down_revision: Union[str, None] = "023_rename_bro_products"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _is_brochet_label(name: str | None) -> bool:
    """Détecte toutes les variantes de plats liés au Brochet (catalogue ou saisie libre)."""
    if not name:
        return False
    n = name.strip().lower()
    return (
        bool(re.search(r"\bbrochet\b", n))
        or "machoiran" in n
        or "faux bro" in n
        or bool(re.search(r"\bbro\b", n))
        or "+bro" in n
    )


def upgrade() -> None:
    bind = op.get_bind()

    # 1. Identifier uniquement l'article Brochet (catégorie PROTEINE) — ne touche aucun autre article
    brochet_row = bind.execute(
        sa.text(
            "SELECT id, quantity, avg_cost_xof FROM stock_articles "
            "WHERE category = 'PROTEINE' "
            "  AND (LOWER(name) = 'brochet' OR LOWER(name) LIKE '%brochet%') "
            "ORDER BY CASE WHEN LOWER(name) = 'brochet' THEN 0 ELSE 1 END "
            "LIMIT 1"
        )
    ).fetchone()

    if not brochet_row:
        return

    brochet_id = str(brochet_row[0])
    current_qty = Decimal(str(brochet_row[1] or 0))
    avg_cost = Decimal(str(brochet_row[2] or 800))

    # 2. Rattacher les fiches recettes manquantes (1.000 pièce) sur tous les plats Brochet du menu
    products_rows = bind.execute(
        sa.text("SELECT id, name FROM products WHERE is_custom = false")
    ).fetchall()

    existing_comp_rows = bind.execute(
        sa.text("SELECT product_id FROM product_components WHERE article_id = :aid"),
        {"aid": brochet_id},
    ).fetchall()
    linked_product_ids = {str(r[0]) for r in existing_comp_rows}

    new_components = []
    for pid_raw, pname in products_rows:
        pid = str(pid_raw)
        if pid not in linked_product_ids and _is_brochet_label(pname):
            new_components.append(
                {
                    "id": str(uuid.uuid4()),
                    "product_id": pid,
                    "article_id": brochet_id,
                    "quantity": Decimal("1.000"),
                }
            )
            linked_product_ids.add(pid)

    if new_components:
        components_table = sa.table(
            "product_components",
            sa.column("id", sa.String),
            sa.column("product_id", sa.String),
            sa.column("article_id", sa.String),
            sa.column("quantity", sa.Numeric),
        )
        op.bulk_insert(components_table, new_components)

    # 3. Rattraper les sorties de stock Brochet non déstockées sur la semaine du 02/11 au 03/11/2026
    #    afin d'aligner le stock physique (7 pièces) sur les ventes réelles sans fausser le stock
    #    de départ (30 pièces) dans la Matrice de Contrôle.
    ref_days = [date(2026, 11, 2), date(2026, 11, 3)]

    prep_rows = bind.execute(
        sa.text(
            "SELECT business_date, prepared_quantity FROM daily_preparations "
            "WHERE article_id = :aid "
            "  AND business_date >= '2026-11-02' AND business_date <= '2026-11-03'"
        ),
        {"aid": brochet_id},
    ).fetchall()
    prep_by_day: dict[str, Decimal] = {
        str(r[0])[:10]: Decimal(str(r[1] or 0)) for r in prep_rows
    }

    order_item_rows = bind.execute(
        sa.text(
            "SELECT cs.business_date, oi.product_id, oi.product_name_snapshot, oi.quantity "
            "FROM order_items oi "
            "JOIN orders o ON o.id = oi.order_id "
            "JOIN cash_sessions cs ON cs.id = o.cash_session_id "
            "WHERE o.status = 'PAID' "
            "  AND oi.removed_at IS NULL "
            "  AND cs.business_date >= '2026-11-02' AND cs.business_date <= '2026-11-03'"
        )
    ).fetchall()

    sold_by_day: dict[str, Decimal] = {}
    for b_date_raw, pid_raw, snap_name, qty_raw in order_item_rows:
        d_str = str(b_date_raw)[:10]
        pid_str = str(pid_raw) if pid_raw else None
        if (pid_str and pid_str in linked_product_ids) or _is_brochet_label(snap_name):
            sold_by_day[d_str] = sold_by_day.get(d_str, Decimal(0)) + Decimal(str(qty_raw or 0))

    # Lundi (clôturé) : sortie validée en matrice (ou ventes si aucune préparation)
    # Mardi : max(sortie validée, ventes payées du jour) pour inclure d'éventuelles ventes du soir
    mon_str = ref_days[0].isoformat()
    tue_str = ref_days[1].isoformat()
    consumed_mon = prep_by_day.get(mon_str, sold_by_day.get(mon_str, Decimal(0)))
    consumed_tue = max(
        prep_by_day.get(tue_str, Decimal(0)),
        sold_by_day.get(tue_str, Decimal(0)),
    )
    total_consumed = consumed_mon + consumed_tue

    if total_consumed <= Decimal(0):
        return

    mov_row = bind.execute(
        sa.text(
            "SELECT COALESCE(SUM(quantity), 0) FROM stock_movements "
            "WHERE article_id = :aid "
            "  AND type IN ('SALE_OUT', 'RETURN_IN') "
            "  AND business_date >= '2026-11-02' AND business_date <= '2026-11-03'"
        ),
        {"aid": brochet_id},
    ).fetchone()
    net_sale_movements = Decimal(str(mov_row[0] or 0)) if mov_row else Decimal(0)
    already_deducted = -net_sale_movements

    missing_deduction = (total_consumed - already_deducted).quantize(Decimal("0.001"))
    if missing_deduction <= Decimal(0):
        return

    new_qty = (current_qty - missing_deduction).quantize(Decimal("0.001"))
    now_utc = datetime.now(timezone.utc)

    bind.execute(
        sa.text(
            "UPDATE stock_articles "
            "SET quantity = :new_qty, updated_at = :now "
            "WHERE id = :aid"
        ),
        {"new_qty": new_qty, "now": now_utc, "aid": brochet_id},
    )

    movements_table = sa.table(
        "stock_movements",
        sa.column("id", sa.String),
        sa.column("article_id", sa.String),
        sa.column("type", sa.String),
        sa.column("quantity", sa.Numeric),
        sa.column("quantity_after", sa.Numeric),
        sa.column("unit_cost_xof", sa.Numeric),
        sa.column("business_date", sa.Date),
        sa.column("reason", sa.String),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    op.bulk_insert(
        movements_table,
        [
            {
                "id": str(uuid.uuid4()),
                "article_id": brochet_id,
                "type": "SALE_OUT",
                "quantity": -missing_deduction,
                "quantity_after": new_qty,
                "unit_cost_xof": avg_cost.quantize(Decimal("0.01")),
                "business_date": date(2026, 11, 3),
                "reason": "Rattrapage ventes Brochet (avant liaison fiches recettes)",
                "created_at": now_utc,
            }
        ],
    )


def downgrade() -> None:
    pass
