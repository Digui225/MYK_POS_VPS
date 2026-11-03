"""sync_protein_stock

Revision ID: 025_sync_protein_stock
Revises: 024_fix_brochet_stock
Create Date: 2026-11-03 22:32:00.000000
"""

import re
import unicodedata
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "025_sync_protein_stock"
down_revision: Union[str, None] = "024_fix_brochet_stock"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

AUTO_VALIDATED_NOTE = "Auto-validé à la clôture de caisse"

_DEFAULT_PORTION_BY_KEY: dict[str, float] = {
    "BOEUF": 0.200,
    "MOUTON": 0.286,
    "POULET": 0.250,
    "POULET_PONDEUSE": 0.250,
    "FAUX_BROCHET": 1.000,
    "FAUX_SAUMON": 1.000,
    "SOSSO": 1.000,
    "LOSS": 1.000,
    "CARPE": 1.000,
}


def _normalize(name: str | None) -> str:
    if not name:
        return ""
    n = name.lower().replace("œ", "oe")
    return unicodedata.normalize("NFKD", n).encode("ascii", "ignore").decode("ascii")


def _match_protein_keyword(name: str | None) -> str | None:
    n = _normalize(name)
    if not n:
        return None
    if "pondeuse" in n:
        return "POULET_PONDEUSE"
    if "poulet" in n or "chair" in n:
        return "POULET"
    if (
        bool(re.search(r"\bbrochet\b", n))
        or "machoiran" in n
        or "faux bro" in n
        or bool(re.search(r"\bbro\b", n))
        or "+bro" in n
    ):
        return "FAUX_BROCHET"
    if "saumon" in n:
        return "FAUX_SAUMON"
    if "sosso" in n:
        return "SOSSO"
    if re.search(r"\bloss\b", n):
        return "LOSS"
    if "mouton" in n:
        return "MOUTON"
    if "boeuf" in n:
        return "BOEUF"
    if "carpe" in n:
        return "CARPE"
    return None


def _article_protein_key(name: str) -> str | None:
    a_norm = _normalize(name)
    if "pondeuse" in a_norm:
        return "POULET_PONDEUSE"
    if "poulet" in a_norm:
        return "POULET"
    if "brochet" in a_norm or "machoiran" in a_norm:
        return "FAUX_BROCHET"
    if "saumon" in a_norm:
        return "FAUX_SAUMON"
    if "sosso" in a_norm:
        return "SOSSO"
    if "loss" in a_norm:
        return "LOSS"
    if "mouton" in a_norm:
        return "MOUTON"
    if "boeuf" in a_norm:
        return "BOEUF"
    if "carpe" in a_norm:
        return "CARPE"
    return None


def upgrade() -> None:
    bind = op.get_bind()

    week_start = date(2026, 11, 2)
    week_end = date(2026, 11, 6)
    sync_date = date(2026, 11, 3)

    # Garde-fou : ne pas exécuter si des mouvements postérieurs à la semaine existent déjà
    future_mov = bind.execute(
        sa.text(
            "SELECT 1 FROM stock_movements WHERE business_date > :wend LIMIT 1"
        ),
        {"wend": week_end},
    ).fetchone()
    if future_mov:
        return

    # Vérifier qu'il y a une activité réelle sur la semaine (sinon base neuve / test)
    prep_count_row = bind.execute(
        sa.text(
            "SELECT COUNT(*) FROM daily_preparations "
            "WHERE business_date >= :wstart AND business_date <= :wend"
        ),
        {"wstart": week_start, "wend": week_end},
    ).fetchone()
    paid_count_row = bind.execute(
        sa.text(
            "SELECT COUNT(*) FROM orders o "
            "JOIN cash_sessions cs ON cs.id = o.cash_session_id "
            "WHERE o.status = 'PAID' "
            "  AND cs.business_date >= :wstart AND cs.business_date <= :wend"
        ),
        {"wstart": week_start, "wend": week_end},
    ).fetchone()
    if int((prep_count_row[0] if prep_count_row else 0) or 0) == 0 and int(
        (paid_count_row[0] if paid_count_row else 0) or 0
    ) == 0:
        return

    # 1. Charger les 9 protéines
    article_rows = bind.execute(
        sa.text(
            "SELECT id, name, quantity, avg_cost_xof "
            "FROM stock_articles WHERE category = 'PROTEINE'"
        )
    ).fetchall()
    if not article_rows:
        return

    protein_by_key: dict[str, str] = {}
    for aid_raw, aname, _, _ in article_rows:
        pkey = _article_protein_key(str(aname))
        if pkey and pkey not in protein_by_key:
            protein_by_key[pkey] = str(aid_raw)

    # 2. Fiches techniques existantes pour les protéines
    comp_rows = bind.execute(
        sa.text(
            "SELECT pc.product_id, pc.article_id, pc.quantity "
            "FROM product_components pc "
            "JOIN stock_articles sa ON sa.id = pc.article_id "
            "WHERE sa.category = 'PROTEINE'"
        )
    ).fetchall()
    comps_by_article: dict[str, list[tuple[str, float]]] = {}
    all_linked_product_ids: set[str] = set()
    for pid_raw, aid_raw, cqty_raw in comp_rows:
        pid_str = str(pid_raw)
        aid_str = str(aid_raw)
        comps_by_article.setdefault(aid_str, []).append((pid_str, float(cqty_raw or 1.0)))
        all_linked_product_ids.add(pid_str)

    # 3. Achats marché validés sur la semaine
    purch_rows = bind.execute(
        sa.text(
            "SELECT mpi.article_id, COALESCE(SUM(mpi.quantity), 0) "
            "FROM market_purchase_items mpi "
            "JOIN market_purchase_lists mpl ON mpl.id = mpi.purchase_list_id "
            "WHERE mpl.status = 'COMPLETED' "
            "  AND mpl.business_date >= :wstart AND mpl.business_date <= :wend "
            "GROUP BY mpi.article_id"
        ),
        {"wstart": week_start, "wend": week_end},
    ).fetchall()
    purchased_by_article: dict[str, Decimal] = {
        str(r[0]): Decimal(str(r[1] or 0)) for r in purch_rows
    }

    # 4. Sorties cuisine enregistrées sur la semaine
    prep_rows = bind.execute(
        sa.text(
            "SELECT article_id, business_date, prepared_quantity, notes "
            "FROM daily_preparations "
            "WHERE business_date >= :wstart AND business_date <= :wend"
        ),
        {"wstart": week_start, "wend": week_end},
    ).fetchall()
    prep_map: dict[tuple[str, str], tuple[Decimal, str]] = {
        (str(r[0]), str(r[1])[:10]): (Decimal(str(r[2] or 0)), str(r[3] or ""))
        for r in prep_rows
    }

    # 5. Ventes payées (catalogue + saisie libre « Hors Menu ») sur la semaine
    sales_rows = bind.execute(
        sa.text(
            "SELECT cs.business_date, oi.product_id, oi.product_name_snapshot, "
            "       COALESCE(SUM(oi.quantity), 0) "
            "FROM order_items oi "
            "JOIN orders o ON o.id = oi.order_id "
            "JOIN cash_sessions cs ON cs.id = o.cash_session_id "
            "WHERE o.status = 'PAID' "
            "  AND oi.removed_at IS NULL "
            "  AND cs.business_date >= :wstart AND cs.business_date <= :wend "
            "GROUP BY cs.business_date, oi.product_id, oi.product_name_snapshot"
        ),
        {"wstart": week_start, "wend": week_end},
    ).fetchall()

    sales_by_day_prod: dict[tuple[str, str], int] = {}
    unmapped_sales_by_day_art: dict[tuple[str, str], int] = {}
    for bdate_raw, pid_raw, snap_name, q_raw in sales_rows:
        d_str = str(bdate_raw)[:10]
        pid_str = str(pid_raw) if pid_raw else None
        qty = int(q_raw or 0)
        if pid_str and pid_str in all_linked_product_ids:
            sales_by_day_prod[(d_str, pid_str)] = (
                sales_by_day_prod.get((d_str, pid_str), 0) + qty
            )
        else:
            pkey = _match_protein_keyword(snap_name)
            if pkey and pkey in protein_by_key:
                target_aid = protein_by_key[pkey]
                unmapped_sales_by_day_art[(d_str, target_aid)] = (
                    unmapped_sales_by_day_art.get((d_str, target_aid), 0) + qty
                )

    calendar_days: list[str] = []
    cur_d = week_start
    while cur_d <= week_end:
        calendar_days.append(cur_d.isoformat())
        cur_d += timedelta(days=1)

    now_utc = datetime.now(timezone.utc)
    movements_to_insert = []

    for aid_raw, aname_raw, qty_raw, avg_cost_raw in article_rows:
        aid = str(aid_raw)
        aname = str(aname_raw or "")

        # Règle explicite : ne jamais toucher au stock de Saumon (déjà à 2 après inventaire)
        if "saumon" in _normalize(aname):
            continue

        current_qty = Decimal(str(qty_raw or 0))
        avg_cost = Decimal(str(avg_cost_raw or 0))

        # Somme des mouvements de la semaine (hors OPENING) pour reconstituer l'ouverture exacte
        net_row = bind.execute(
            sa.text(
                "SELECT COALESCE(SUM(quantity), 0) FROM stock_movements "
                "WHERE article_id = :aid "
                "  AND business_date >= :wstart AND business_date <= :wend "
                "  AND type <> 'OPENING'"
            ),
            {"aid": aid, "wstart": week_start, "wend": week_end},
        ).fetchone()
        in_period_net = Decimal(str(net_row[0] or 0)) if net_row else Decimal("0")

        opening_qty = max(Decimal("0"), current_qty - in_period_net).quantize(Decimal("0.001"))
        p_qty = purchased_by_article.get(aid, Decimal("0")).quantize(Decimal("0.001"))
        tot_available = (opening_qty + p_qty).quantize(Decimal("0.001"))
        if tot_available <= Decimal("0") and current_qty > Decimal("0"):
            tot_available = current_qty.quantize(Decimal("0.001"))

        comps = comps_by_article.get(aid, [])
        pkey = _article_protein_key(aname)
        standard_portion = (
            comps[0][1]
            if comps
            else (_DEFAULT_PORTION_BY_KEY.get(pkey, 1.0) if pkey else 1.0)
        )
        default_yield = round(1.0 / standard_portion, 2) if standard_portion > 0 else 1.0

        tot_consumed = Decimal("0")
        for d_str in calendar_days:
            day_sold = sum(
                sales_by_day_prod.get((d_str, c_pid), 0) for c_pid, _ in comps
            ) + unmapped_sales_by_day_art.get((d_str, aid), 0)
            suggested_q = (
                Decimal(str(round(day_sold / default_yield, 2)))
                if (day_sold > 0 and default_yield > 0)
                else Decimal("0")
            )
            prep_entry = prep_map.get((aid, d_str))
            if prep_entry is not None:
                prep_qty, prep_notes = prep_entry
                if AUTO_VALIDATED_NOTE in prep_notes:
                    tot_consumed += max(prep_qty, suggested_q)
                else:
                    tot_consumed += prep_qty
            else:
                tot_consumed += suggested_q

        target_qty = max(Decimal("0"), tot_available - tot_consumed).quantize(
            Decimal("0.001")
        )
        delta = (target_qty - current_qty).quantize(Decimal("0.001"))
        if delta == Decimal("0"):
            continue

        bind.execute(
            sa.text(
                "UPDATE stock_articles "
                "SET quantity = :target_qty, updated_at = :now "
                "WHERE id = :aid"
            ),
            {"target_qty": target_qty, "now": now_utc, "aid": aid},
        )

        mov_type = "SALE_OUT" if delta < Decimal("0") else "ADJUSTMENT"
        movements_to_insert.append(
            {
                "id": str(uuid.uuid4()),
                "article_id": aid,
                "type": mov_type,
                "quantity": delta,
                "quantity_after": target_qty,
                "unit_cost_xof": avg_cost.quantize(Decimal("0.01")),
                "business_date": sync_date,
                "reason": "Synchronisation stock protéines avec ventes réelles (hors menu inclus)",
                "created_at": now_utc,
            }
        )

    if movements_to_insert:
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
        op.bulk_insert(movements_table, movements_to_insert)


def downgrade() -> None:
    pass

