"""Règle universelle du stock protéines (D6, MEMORY.md) : lecture commune à la vente,
à la matrice de contrôle, à l'estimation des sorties cuisine et aux rapports.

- `ProteinResolver` : quelle protéine (et quelle quantité) consomme un plat vendu.
- `daily_ledger` : grand livre jour par jour lu dans `stock_movements`, seule source du stock :
  Restant = Ouverture + Achats − Ventes − Pertes ± Écart d'inventaire ± Corrections.
  Un stock de départ (premier comptage) saisi pendant la période compte dans l'ouverture.
  Le restant du dernier jour est, par construction, la quantité en stock à cette date.
"""

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain import stock_rules
from caisse.domain.enums import OrderStatus, StockArticleCategory
from caisse.domain.protein_mapping import (
    article_protein_key,
    match_protein_keyword,
    standard_portion,
)
from caisse.models.cash_session import CashSession
from caisse.models.order import Order, OrderItem
from caisse.models.stock import ProductComponent, StockArticle, StockMovement

_ZERO = Decimal(0)


# --- Rattachement plat → protéine -------------------------------------------------------


@dataclass
class ProteinResolver:
    """Photographie des protéines et de leurs fiches techniques à un instant donné."""

    articles: list[StockArticle]
    by_key: dict[str, StockArticle]
    recipes: dict[str, list[tuple[str, Decimal]]]
    portions: dict[str, Decimal]
    components_by_article: dict[str, list[ProductComponent]] = field(default_factory=dict)

    def fallback(self, dish_name: str | None) -> tuple[str, Decimal] | None:
        """Plat sans fiche protéine : protéine citée dans le libellé, à sa portion standard."""
        key = match_protein_keyword(dish_name)
        article = self.by_key.get(key) if key else None
        if article is None:
            return None
        return str(article.id), self.portions[str(article.id)]

    def protein_lines(
        self, product_id: str | None, dish_name: str | None
    ) -> list[tuple[str, Decimal]]:
        """[(article protéine, quantité par plat)] consommés par un plat vendu."""
        recipe = self.recipes.get(str(product_id)) if product_id else None
        if recipe:
            return recipe
        fb = self.fallback(dish_name)
        return [fb] if fb else []

    def portion(self, article_id: str) -> Decimal:
        return self.portions.get(str(article_id), Decimal("1.000"))


def build_resolver(db: Session) -> ProteinResolver:
    articles = (
        db.query(StockArticle)
        .filter(StockArticle.category == StockArticleCategory.PROTEINE)
        .order_by(StockArticle.name)
        .all()
    )
    ids = [str(a.id) for a in articles]
    components = (
        db.query(ProductComponent).filter(ProductComponent.article_id.in_(ids)).all()
        if ids
        else []
    )
    recipes: dict[str, list[tuple[str, Decimal]]] = defaultdict(list)
    by_article: dict[str, list[ProductComponent]] = defaultdict(list)
    for c in components:
        recipes[str(c.product_id)].append((str(c.article_id), Decimal(c.quantity)))
        by_article[str(c.article_id)].append(c)

    portions = {
        str(a.id): standard_portion(
            (Decimal(c.quantity) for c in by_article.get(str(a.id), [])),
            article_protein_key(a.name),
        )
        for a in articles
    }

    # Une protéine par clé : l'article actif d'abord, puis l'ordre alphabétique
    by_key: dict[str, StockArticle] = {}
    for a in sorted(articles, key=lambda a: (not a.is_active, a.name)):
        key = article_protein_key(a.name)
        if key and key not in by_key and a.is_active:
            by_key[key] = a

    return ProteinResolver(
        articles=articles,
        by_key=by_key,
        recipes=dict(recipes),
        portions=portions,
        components_by_article=dict(by_article),
    )


# --- Ventes payées ---------------------------------------------------------------------


@dataclass(frozen=True)
class SaleLine:
    business_date: date
    item_id: str
    product_id: str | None
    name: str
    quantity: int
    revenue_xof: int


def paid_sale_lines(db: Session, date_from: date, date_to: date) -> list[SaleLine]:
    """Lignes des commandes soldées, datées de la journée de caisse."""
    rows = db.execute(
        select(
            CashSession.business_date,
            OrderItem.id,
            OrderItem.product_id,
            OrderItem.product_name_snapshot,
            OrderItem.quantity,
            OrderItem.line_total_xof,
        )
        .join(Order, Order.cash_session_id == CashSession.id)
        .join(OrderItem, OrderItem.order_id == Order.id)
        .where(
            Order.status == OrderStatus.PAID,
            CashSession.business_date >= date_from,
            CashSession.business_date <= date_to,
            OrderItem.removed_at.is_(None),
        )
    ).all()
    return [
        SaleLine(
            business_date=d,
            item_id=str(iid),
            product_id=str(pid) if pid else None,
            name=name or "",
            quantity=int(q or 0),
            revenue_xof=int(rev or 0),
        )
        for d, iid, pid, name, q, rev in rows
    ]


def destocked_by_item(db: Session, item_ids: list[str]) -> dict[tuple[str, str], Decimal]:
    """(ligne de commande, article) → quantité nette sortie du stock pour cette ligne."""
    result: dict[tuple[str, str], Decimal] = {}
    for start in range(0, len(item_ids), 500):
        chunk = item_ids[start : start + 500]
        rows = db.execute(
            select(
                StockMovement.reference_order_item_id,
                StockMovement.article_id,
                func.sum(StockMovement.quantity),
            )
            .where(StockMovement.reference_order_item_id.in_(chunk))
            .group_by(StockMovement.reference_order_item_id, StockMovement.article_id)
        ).all()
        for iid, aid, qty in rows:
            result[(str(iid), str(aid))] = -Decimal(qty or 0)
    return result


# --- Grand livre ------------------------------------------------------------------------


@dataclass
class LedgerDay:
    business_date: date
    opening: Decimal = _ZERO
    purchases: Decimal = _ZERO
    purchases_value: Decimal = _ZERO
    sales: Decimal = _ZERO  # quantité sortie par les ventes (positive), retours déduits
    losses: Decimal = _ZERO  # quantité perdue (positive)
    inventory: Decimal = _ZERO  # écart d'inventaire signé
    corrections: Decimal = _ZERO  # corrections signées (ajustements, rattrapages)
    closing: Decimal = _ZERO

    @property
    def available(self) -> Decimal:
        """Disponible dans la journée : ouverture + achats du jour."""
        return self.opening + self.purchases


def consumed_quantity(days: list[LedgerDay]) -> Decimal:
    """Matière consommée sur la période : ventes + pertes + manquant net d'inventaire et de
    corrections. Inventaires et corrections sont compensés entre eux avant de retenir un
    manquant : un comptage à +6 annulé par une correction à −6 ne consomme rien."""
    sales = sum((d.sales for d in days), _ZERO)
    losses = sum((d.losses for d in days), _ZERO)
    adjustments = sum((d.inventory + d.corrections for d in days), _ZERO)
    return sales + losses + max(_ZERO, -adjustments)


def calendar(date_from: date, date_to: date) -> list[date]:
    days: list[date] = []
    cur = date_from
    while cur <= date_to:
        days.append(cur)
        cur += timedelta(days=1)
    return days


def daily_ledger(
    db: Session, articles: list[StockArticle], date_from: date, date_to: date
) -> dict[str, list[LedgerDay]]:
    """Grand livre de chaque article, une ligne par jour de la période."""
    ids = [str(a.id) for a in articles]
    if not ids:
        return {}
    has_order = StockMovement.reference_order_id.isnot(None)
    rows = db.execute(
        select(
            StockMovement.article_id,
            StockMovement.business_date,
            StockMovement.type,
            has_order,
            func.sum(StockMovement.quantity),
            func.sum(StockMovement.quantity * StockMovement.unit_cost_xof),
        )
        .where(
            StockMovement.article_id.in_(ids),
            StockMovement.business_date >= date_from,
            StockMovement.business_date <= date_to,
        )
        .group_by(StockMovement.article_id, StockMovement.business_date, StockMovement.type, has_order)
    ).all()
    after_rows = db.execute(
        select(StockMovement.article_id, func.sum(StockMovement.quantity))
        .where(StockMovement.article_id.in_(ids), StockMovement.business_date > date_to)
        .group_by(StockMovement.article_id)
    ).all()
    after = {str(aid): Decimal(q or 0) for aid, q in after_rows}

    # (article, jour) → colonne → (quantité signée, valeur signée)
    cells: dict[tuple[str, date], dict[str, tuple[Decimal, Decimal]]] = defaultdict(dict)
    net_period: dict[str, Decimal] = defaultdict(lambda: _ZERO)
    for aid, day, m_type, with_order, qty, val in rows:
        bucket = stock_rules.ledger_bucket(str(m_type), bool(with_order))
        q, v = Decimal(qty or 0), Decimal(val or 0)
        if bucket == stock_rules.LEDGER_OPENING:
            # le stock de départ saisi pendant la période compte dans l'ouverture
            continue
        cur_q, cur_v = cells[(str(aid), day)].get(bucket, (_ZERO, _ZERO))
        cells[(str(aid), day)][bucket] = (cur_q + q, cur_v + v)
        net_period[str(aid)] += q

    days = calendar(date_from, date_to)
    ledger: dict[str, list[LedgerDay]] = {}
    for a in articles:
        aid = str(a.id)
        closing_end = Decimal(a.quantity) - after.get(aid, _ZERO)
        running = closing_end - net_period.get(aid, _ZERO)
        lines: list[LedgerDay] = []
        for d in days:
            c = cells.get((aid, d), {})
            line = LedgerDay(
                business_date=d,
                opening=running,
                purchases=c.get(stock_rules.LEDGER_PURCHASES, (_ZERO, _ZERO))[0],
                purchases_value=c.get(stock_rules.LEDGER_PURCHASES, (_ZERO, _ZERO))[1],
                sales=-c.get(stock_rules.LEDGER_SALES, (_ZERO, _ZERO))[0],
                losses=-c.get(stock_rules.LEDGER_LOSSES, (_ZERO, _ZERO))[0],
                inventory=c.get(stock_rules.LEDGER_INVENTORY, (_ZERO, _ZERO))[0],
                corrections=c.get(stock_rules.LEDGER_CORRECTIONS, (_ZERO, _ZERO))[0],
            )
            running = (
                running + line.purchases - line.sales - line.losses + line.inventory
                + line.corrections
            )
            line.closing = running
            lines.append(line)
        ledger[aid] = lines
    return ledger
