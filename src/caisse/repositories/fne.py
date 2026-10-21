import uuid
from datetime import date, datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    FneDocumentType,
    FneStatus,
    OrderStatus,
    PaymentMethod,
    PaymentStatus,
)
from caisse.models.customer import Customer
from caisse.models.fne import FneDocument
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.pagination import PageRequest, newest_first

# en attente d'une action (certification, renvoi ou vérification)
PENDING_STATUSES = (FneStatus.PENDING, FneStatus.QUEUED, FneStatus.SUBMITTING, FneStatus.FAILED)


def get(db: Session, document_id: uuid.UUID) -> FneDocument | None:
    return db.get(FneDocument, document_id)


def get_for_update(db: Session, document_id: uuid.UUID) -> FneDocument | None:
    return db.scalar(select(FneDocument).where(FneDocument.id == document_id).with_for_update())


def next_due(db: Session, now: datetime) -> FneDocument | None:
    """Plus ancien document en file dont le renvoi est échu, verrouillé ; un document déjà pris
    par un autre processus est sauté. Jamais un document incertain (PLAN-FNE D5)."""
    return db.scalar(
        select(FneDocument)
        .where(
            FneDocument.status == FneStatus.QUEUED,
            FneDocument.is_uncertain.is_(False),
            FneDocument.next_retry_at <= now,
        )
        .order_by(FneDocument.next_retry_at, FneDocument.id)
        .limit(1)
        .with_for_update(skip_locked=True)
    )


def sale_for_order(db: Session, order_id: uuid.UUID) -> FneDocument | None:
    return db.scalar(
        select(FneDocument).where(
            FneDocument.order_id == order_id, FneDocument.type == FneDocumentType.FNE
        )
    )


def refunds_of(db: Session, parent_id: uuid.UUID) -> list[FneDocument]:
    return list(
        db.scalars(
            select(FneDocument)
            .where(FneDocument.parent_document_id == parent_id)
            .order_by(FneDocument.created_at)
        )
    )


def list_documents(
    db: Session, *, status: FneStatus | None, business_date: date | None, page: PageRequest
) -> list[FneDocument]:
    """Une ligne de plus que la page (voir `pagination.split`)."""
    stmt = newest_first(select(FneDocument), FneDocument.created_at, FneDocument.id, page)
    if status is not None:
        stmt = stmt.where(FneDocument.status == status)
    if business_date is not None:
        stmt = stmt.join(Order, Order.id == FneDocument.order_id).where(
            Order.business_date == business_date
        )
    return list(db.scalars(stmt))


def export_rows(
    db: Session, *, status: FneStatus | None, date_from: date | None, date_to: date | None
) -> list[tuple[FneDocument, Order | None, Customer | None]]:
    """Documents avec leur commande et leur client, par date de création ; journée de la
    commande pour le filtre de période."""
    stmt = (
        select(FneDocument, Order, Customer)
        .outerjoin(Order, Order.id == FneDocument.order_id)
        .outerjoin(Customer, Customer.id == FneDocument.customer_id)
        .order_by(FneDocument.created_at, FneDocument.id)
    )
    if status is not None:
        stmt = stmt.where(FneDocument.status == status)
    if date_from is not None:
        stmt = stmt.where(Order.business_date >= date_from)
    if date_to is not None:
        stmt = stmt.where(Order.business_date <= date_to)
    return [(doc, order, customer) for doc, order, customer in db.execute(stmt)]


def pending_counts(db: Session) -> tuple[int, int, int]:
    """(en attente, dont incertains, dont refusés)."""
    row = db.execute(
        select(
            func.count(),
            func.count().filter(FneDocument.is_uncertain.is_(True)),
            func.count().filter(FneDocument.status == FneStatus.FAILED),
        ).where(FneDocument.status.in_(PENDING_STATUSES))
    ).one()
    return int(row[0]), int(row[1]), int(row[2])


def order_numbers(db: Session, order_ids: set[uuid.UUID]) -> dict[uuid.UUID, str]:
    if not order_ids:
        return {}
    rows = db.execute(select(Order.id, Order.order_number).where(Order.id.in_(order_ids)))
    return {order_id: number for order_id, number in rows}


def captured_payments(db: Session, order_id: uuid.UUID) -> list[tuple[PaymentMethod, int]]:
    rows = db.execute(
        select(Payment.method, Payment.amount_xof)
        .where(Payment.order_id == order_id, Payment.status == PaymentStatus.CAPTURED)
        .order_by(Payment.created_at)
    )
    return [(method, amount) for method, amount in rows]


def paid_orders_totals(db: Session, business_date: date) -> tuple[int, int]:
    row = db.execute(
        select(func.count(), func.coalesce(func.sum(Order.total_ttc_xof), 0)).where(
            Order.business_date == business_date, Order.status == OrderStatus.PAID
        )
    ).one()
    return int(row[0]), int(row[1])


def certified_orders_totals(db: Session, business_date: date) -> tuple[int, int]:
    row = db.execute(
        select(func.count(), func.coalesce(func.sum(Order.total_ttc_xof), 0))
        .join(FneDocument, FneDocument.order_id == Order.id)
        .where(
            Order.business_date == business_date,
            FneDocument.type == FneDocumentType.FNE,
            FneDocument.status == FneStatus.CERTIFIED,
        )
    ).one()
    return int(row[0]), int(row[1])


def pending_for_date(db: Session, business_date: date) -> int:
    return int(
        db.scalar(
            select(func.count())
            .select_from(FneDocument)
            .join(Order, Order.id == FneDocument.order_id)
            .where(Order.business_date == business_date, FneDocument.status.in_(PENDING_STATUSES))
        )
        or 0
    )


def fiscal_group_totals(db: Session, business_date: date) -> list[tuple[str, int, int]]:
    rows = db.execute(
        select(
            OrderItem.fiscal_group_snapshot,
            func.sum(OrderItem.quantity),
            func.sum(OrderItem.line_total_xof),
        )
        .join(Order, Order.id == OrderItem.order_id)
        .where(
            Order.business_date == business_date,
            Order.status == OrderStatus.PAID,
            OrderItem.removed_at.is_(None),
        )
        .group_by(OrderItem.fiscal_group_snapshot)
        .order_by(OrderItem.fiscal_group_snapshot)
    )
    return [(group, int(qty), int(amount)) for group, qty, amount in rows]
