"""Agrégats des tableaux de bord : une requête groupée par axe."""

from datetime import date
from decimal import Decimal

from sqlalchemy import ColumnElement, func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    ACTIVE_ORDER_STATUSES,
    OrderStatus,
    PaymentMethod,
    PaymentStatus,
    StockMovementType,
    StockOutMode,
)
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.table import RestaurantTable
from caisse.models.user import User
from caisse.repositories.stock import SALE_TYPES

NON_SALE_OUT_TYPES = (
    StockMovementType.LOSS_OUT,
    StockMovementType.INVENTORY_COUNT,
    StockMovementType.ADJUSTMENT,
)

_ZERO = Decimal(0)


def _paid_in(date_from: date, date_to: date) -> ColumnElement[bool]:
    return (
        (Order.status == OrderStatus.PAID)
        & (CashSession.business_date >= date_from)
        & (CashSession.business_date <= date_to)
    )


def _value() -> ColumnElement[Decimal]:
    return func.coalesce(func.sum(StockMovement.quantity * StockMovement.unit_cost_xof), _ZERO)


# --- Ventes ------------------------------------------------------------------------------


def sales_by_day(db: Session, date_from: date, date_to: date) -> list[tuple[date, int, int]]:
    """(journée, commandes, chiffre d'affaires)."""
    rows = db.execute(
        select(CashSession.business_date, func.count(Order.id), func.sum(Order.total_ttc_xof))
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(_paid_in(date_from, date_to))
        .group_by(CashSession.business_date)
        .order_by(CashSession.business_date)
    )
    return [(d, int(n), int(total or 0)) for d, n, total in rows]


def recipe_cost_by_day(db: Session, date_from: date, date_to: date) -> dict[date, Decimal]:
    """Coût matière net des ventes (sorties - remises en stock), positif."""
    rows = db.execute(
        select(CashSession.business_date, -_value())
        .select_from(StockMovement)
        .join(Order, Order.id == StockMovement.reference_order_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(StockMovement.type.in_(SALE_TYPES), _paid_in(date_from, date_to))
        .group_by(CashSession.business_date)
    )
    return {d: Decimal(cost) for d, cost in rows}


def purchases_by_day(db: Session, date_from: date, date_to: date) -> dict[date, Decimal]:
    """Total des achats reçus (PURCHASE_IN) par jour ouvrable."""
    rows = db.execute(
        select(StockMovement.business_date, _value())
        .where(
            StockMovement.type == StockMovementType.PURCHASE_IN,
            StockMovement.business_date >= date_from,
            StockMovement.business_date <= date_to,
        )
        .group_by(StockMovement.business_date)
    )
    return {d: Decimal(val) for d, val in rows}


def non_sale_out_by_day(db: Session, date_from: date, date_to: date) -> dict[date, Decimal]:
    """Valeur des consommations hors vente (pertes, écarts d'inventaire) par jour ouvrable."""
    rows = db.execute(
        select(StockMovement.business_date, -_value())
        .where(
            StockMovement.type.in_(NON_SALE_OUT_TYPES),
            StockMovement.business_date >= date_from,
            StockMovement.business_date <= date_to,
        )
        .group_by(StockMovement.business_date)
    )
    return {d: Decimal(val) for d, val in rows}


def sales_by_product(
    db: Session, date_from: date, date_to: date
) -> list[tuple[str, str, str, int, int]]:
    """(produit, nom, catégorie, quantité, chiffre d'affaires)."""
    rows = db.execute(
        select(
            OrderItem.product_id,
            func.max(OrderItem.product_name_snapshot),
            func.max(OrderItem.category_snapshot),
            func.sum(OrderItem.quantity),
            func.sum(OrderItem.line_total_xof),
        )
        .join(Order, Order.id == OrderItem.order_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(_paid_in(date_from, date_to), OrderItem.removed_at.is_(None))
        .group_by(OrderItem.product_id)
    )
    return [(str(pid), name, cat, int(qty), int(total)) for pid, name, cat, qty, total in rows]


def recipe_cost_by_product(db: Session, date_from: date, date_to: date) -> dict[str, Decimal]:
    rows = db.execute(
        select(OrderItem.product_id, -_value())
        .select_from(StockMovement)
        .join(OrderItem, OrderItem.id == StockMovement.reference_order_item_id)
        .join(Order, Order.id == StockMovement.reference_order_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(StockMovement.type.in_(SALE_TYPES), _paid_in(date_from, date_to))
        .group_by(OrderItem.product_id)
    )
    return {str(pid): Decimal(cost) for pid, cost in rows}


def payments_by_method(
    db: Session, date_from: date, date_to: date
) -> list[tuple[PaymentMethod, int, int]]:
    rows = db.execute(
        select(Payment.method, func.count(Payment.id), func.sum(Payment.amount_xof))
        .join(Order, Order.id == Payment.order_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(Payment.status == PaymentStatus.CAPTURED, _paid_in(date_from, date_to))
        .group_by(Payment.method)
        .order_by(func.sum(Payment.amount_xof).desc())
    )
    return [(PaymentMethod(method), int(n), int(total or 0)) for method, n, total in rows]


def cash_sessions(db: Session, date_from: date, date_to: date) -> list[CashSession]:
    return list(
        db.scalars(
            select(CashSession)
            .where(CashSession.business_date >= date_from, CashSession.business_date <= date_to)
            .order_by(CashSession.business_date, CashSession.opened_at)
        )
    )


def non_sale_out_by_mode(
    db: Session, date_from: date, date_to: date
) -> dict[StockOutMode, Decimal]:
    """Valeur sortie hors ventes (pertes, écarts d'inventaire), positive, par mode de suivi."""
    rows = db.execute(
        select(StockArticle.out_mode, -_value())
        .select_from(StockMovement)
        .join(StockArticle, StockArticle.id == StockMovement.article_id)
        .where(
            StockMovement.type.in_(NON_SALE_OUT_TYPES),
            StockMovement.business_date >= date_from,
            StockMovement.business_date <= date_to,
        )
        .group_by(StockArticle.out_mode)
    )
    return {mode: Decimal(value) for mode, value in rows}


# --- Stock -------------------------------------------------------------------------------


def movements_by_article_type(
    db: Session, date_from: date, date_to: date
) -> dict[tuple[str, StockMovementType], tuple[Decimal, Decimal]]:
    """(article, type) → (quantité signée, valeur signée) sur la période."""
    rows = db.execute(
        select(
            StockMovement.article_id,
            StockMovement.type,
            func.sum(StockMovement.quantity),
            _value(),
        )
        .where(StockMovement.business_date >= date_from, StockMovement.business_date <= date_to)
        .group_by(StockMovement.article_id, StockMovement.type)
    )
    return {(str(aid), t): (Decimal(qty), Decimal(val)) for aid, t, qty, val in rows}


def quantity_after(db: Session, day: date) -> dict[str, Decimal]:
    """Quantité signée des mouvements postérieurs à `day`, par article."""
    rows = db.execute(
        select(StockMovement.article_id, func.sum(StockMovement.quantity))
        .where(StockMovement.business_date > day)
        .group_by(StockMovement.article_id)
    )
    return {str(aid): Decimal(qty) for aid, qty in rows}


def last_count_dates(db: Session, day: date) -> dict[str, date]:
    """Dernier inventaire (ou ouverture) de chaque article au plus tard à `day`."""
    rows = db.execute(
        select(StockMovement.article_id, func.max(StockMovement.business_date))
        .where(
            StockMovement.type.in_((StockMovementType.INVENTORY_COUNT, StockMovementType.OPENING)),
            StockMovement.business_date <= day,
        )
        .group_by(StockMovement.article_id)
    )
    return {str(aid): d for aid, d in rows}


# --- Tableau de bord du jour -------------------------------------------------------------


def day_orders(db: Session, day: date) -> tuple[int, int, int, int, int, int, int]:
    """(soldées, CA, couverts, à table, à emporter, ouvertes, annulées) de la journée."""
    paid = Order.status == OrderStatus.PAID
    row = db.execute(
        select(
            func.count().filter(paid),
            func.coalesce(func.sum(Order.total_ttc_xof).filter(paid), 0),
            func.coalesce(func.sum(Order.guests_count).filter(paid), 0),
            func.count().filter(paid & Order.table_id.is_not(None)),
            func.count().filter(paid & Order.table_id.is_(None)),
            func.count().filter(Order.status.in_(ACTIVE_ORDER_STATUSES)),
            func.count().filter(Order.status == OrderStatus.CANCELLED),
        )
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(CashSession.business_date == day)
    ).one()
    return tuple(int(v) for v in row)  # type: ignore[return-value]


def tables_occupancy(db: Session) -> tuple[int, int]:
    """(tables en service qui portent une commande active, tables en service)."""
    occupied = db.scalar(
        select(func.count(func.distinct(Order.table_id)))
        .join(RestaurantTable, RestaurantTable.id == Order.table_id)
        .where(Order.status.in_(ACTIVE_ORDER_STATUSES), RestaurantTable.is_active.is_(True))
    )
    total = db.scalar(
        select(func.count()).select_from(RestaurantTable).where(RestaurantTable.is_active.is_(True))
    )
    return int(occupied or 0), int(total or 0)


def payments_by_method_provider(
    db: Session, day: date
) -> list[tuple[PaymentMethod, str | None, int, int]]:
    rows = db.execute(
        select(
            Payment.method, Payment.provider, func.count(Payment.id), func.sum(Payment.amount_xof)
        )
        .join(Order, Order.id == Payment.order_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(Payment.status == PaymentStatus.CAPTURED, _paid_in(day, day))
        .group_by(Payment.method, Payment.provider)
        .order_by(func.sum(Payment.amount_xof).desc())
    )
    return [(PaymentMethod(m), p, int(n), int(total or 0)) for m, p, n, total in rows]


def sales_by_hour(db: Session, day: date) -> list[tuple[int, int, int]]:
    """(heure d'encaissement, commandes, CA) ; Abidjan est à UTC."""
    hour = func.extract("hour", func.timezone("UTC", Order.paid_at))
    rows = db.execute(
        select(hour, func.count(Order.id), func.sum(Order.total_ttc_xof))
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(_paid_in(day, day), Order.paid_at.is_not(None))
        .group_by(hour)
        .order_by(hour)
    )
    return [(int(h), int(n), int(total or 0)) for h, n, total in rows]


def sales_by_closer(db: Session, day: date) -> list[tuple[str, str, int, int]]:
    rows = db.execute(
        select(User.id, User.full_name, func.count(Order.id), func.sum(Order.total_ttc_xof))
        .join(User, User.id == Order.closed_by_user_id)
        .join(CashSession, Order.cash_session_id == CashSession.id)
        .where(_paid_in(day, day))
        .group_by(User.id, User.full_name)
        .order_by(func.sum(Order.total_ttc_xof).desc())
    )
    return [(str(uid), name, int(n), int(total or 0)) for uid, name, n, total in rows]


def day_sessions(db: Session, day: date) -> list[tuple[CashSession, str, str]]:
    """Sessions de la journée avec le nom de la caisse et de qui l'a ouverte."""
    rows = db.execute(
        select(CashSession, CashRegister.name, User.full_name)
        .join(CashRegister, CashRegister.id == CashSession.cash_register_id)
        .join(User, User.id == CashSession.opened_by_user_id)
        .where(CashSession.business_date == day)
        .order_by(CashSession.opened_at)
    )
    return [(s, register, opener) for s, register, opener in rows]
