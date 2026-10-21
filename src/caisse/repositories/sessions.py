import uuid
from datetime import date

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    ACTIVE_ORDER_STATUSES,
    CashMovementType,
    CashSessionStatus,
    OrderStatus,
    PaymentMethod,
    PaymentStatus,
)
from caisse.models.cash_session import CashMovement, CashRegister, CashSession
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.models.print_job import PrintJob
from caisse.pagination import PageRequest, newest_first


def list_registers(db: Session, *, is_active: bool | None = True) -> list[CashRegister]:
    stmt = select(CashRegister).order_by(CashRegister.created_at, CashRegister.name)
    if is_active is not None:
        stmt = stmt.where(CashRegister.is_active.is_(is_active))
    return list(db.scalars(stmt))


def get(db: Session, session_id: uuid.UUID) -> CashSession | None:
    return db.get(CashSession, session_id)


def get_open_for_register(db: Session, register_id: uuid.UUID) -> CashSession | None:
    return db.scalar(
        select(CashSession).where(
            CashSession.cash_register_id == register_id,
            CashSession.status != CashSessionStatus.CLOSED,
        )
    )


def get_closed_same_day(
    db: Session, register_id: uuid.UUID, business_date: date
) -> CashSession | None:
    return db.scalar(
        select(CashSession)
        .where(
            CashSession.cash_register_id == register_id,
            CashSession.business_date == business_date,
            CashSession.status == CashSessionStatus.CLOSED,
        )
        .order_by(CashSession.closed_at.desc())
        .limit(1)
    )


def list_history(
    db: Session, *, register_id: uuid.UUID | None = None, page: PageRequest | None = None
) -> list[CashSession]:
    """Une ligne de plus que la page (voir `pagination.split`)."""
    stmt = newest_first(
        select(CashSession).where(CashSession.status == CashSessionStatus.CLOSED),
        CashSession.closed_at,
        CashSession.id,
        page or PageRequest(),
    )
    if register_id is not None:
        stmt = stmt.where(CashSession.cash_register_id == register_id)
    return list(db.scalars(stmt))


def open_orders(db: Session, session_id: uuid.UUID) -> list[Order]:
    return list(
        db.scalars(
            select(Order).where(
                Order.cash_session_id == session_id, Order.status.in_(ACTIVE_ORDER_STATUSES)
            )
        )
    )


def payment_totals_by_method(db: Session, session_id: uuid.UUID) -> list[tuple[str, int, int]]:
    rows = db.execute(
        select(Payment.method, func.sum(Payment.amount_xof), func.count())
        .where(Payment.cash_session_id == session_id, Payment.status == PaymentStatus.CAPTURED)
        .group_by(Payment.method)
        .order_by(Payment.method)
    ).all()
    return [(str(method), int(amount), int(count)) for method, amount, count in rows]


def cash_captured_total(db: Session, session_id: uuid.UUID) -> int:
    total = db.scalar(
        select(func.coalesce(func.sum(Payment.amount_xof), 0)).where(
            Payment.cash_session_id == session_id,
            Payment.status == PaymentStatus.CAPTURED,
            Payment.method == PaymentMethod.CASH,
        )
    )
    return int(total or 0)


def fiscal_group_totals(db: Session, session_id: uuid.UUID) -> list[tuple[str, int, int]]:
    rows = db.execute(
        select(
            OrderItem.fiscal_group_snapshot,
            func.sum(OrderItem.quantity),
            func.sum(OrderItem.line_total_xof),
        )
        .join(Order, Order.id == OrderItem.order_id)
        .where(
            Order.cash_session_id == session_id,
            Order.status == OrderStatus.PAID,
            OrderItem.removed_at.is_(None),
        )
        .group_by(OrderItem.fiscal_group_snapshot)
        .order_by(OrderItem.fiscal_group_snapshot)
    ).all()
    return [(group, int(qty), int(amount)) for group, qty, amount in rows]


def movements_sum(db: Session, session_id: uuid.UUID) -> tuple[int, int]:
    row = db.execute(
        select(
            func.coalesce(
                func.sum(CashMovement.amount_xof).filter(CashMovement.type == CashMovementType.IN),
                0,
            ),
            func.coalesce(
                func.sum(CashMovement.amount_xof).filter(CashMovement.type == CashMovementType.OUT),
                0,
            ),
        ).where(CashMovement.cash_session_id == session_id)
    ).one()
    return int(row[0]), int(row[1])


def orders_count_and_gross(db: Session, session_id: uuid.UUID) -> tuple[int, int]:
    row = db.execute(
        select(func.count(), func.coalesce(func.sum(Order.total_ttc_xof), 0)).where(
            Order.cash_session_id == session_id, Order.status == OrderStatus.PAID
        )
    ).one()
    return int(row[0]), int(row[1])


def vat_total(db: Session, session_id: uuid.UUID) -> int:
    total = db.scalar(
        select(func.coalesce(func.sum(Order.total_vat_xof), 0)).where(
            Order.cash_session_id == session_id, Order.status == OrderStatus.PAID
        )
    )
    return int(total or 0)


def controls(db: Session, session_id: uuid.UUID) -> tuple[int, int, int]:
    cancelled_orders = db.scalar(
        select(func.count()).where(
            Order.cash_session_id == session_id, Order.status == OrderStatus.CANCELLED
        )
    )
    removed_items = db.scalar(
        select(func.count())
        .select_from(OrderItem)
        .join(Order, Order.id == OrderItem.order_id)
        .where(Order.cash_session_id == session_id, OrderItem.removed_at.is_not(None))
    )
    reprints = db.scalar(
        select(func.count())
        .select_from(PrintJob)
        .join(Order, Order.id == PrintJob.order_id)
        .where(Order.cash_session_id == session_id, PrintJob.is_reprint.is_(True))
    )
    return int(cancelled_orders or 0), int(removed_items or 0), int(reprints or 0)
