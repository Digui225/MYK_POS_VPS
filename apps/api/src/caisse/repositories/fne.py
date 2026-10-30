from datetime import date, datetime
from typing import Optional

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    FneDocumentType,
    FneStatus,
    OrderStatus,
    PaymentMethod,
)
from caisse.models.cash_session import CashSession
from caisse.models.fne import FneDocument
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment

# en attente d'une action (certification, renvoi ou vérification)
PENDING_STATUSES = (FneStatus.PENDING, FneStatus.QUEUED, FneStatus.SUBMITTING, FneStatus.FAILED)


def get(db: Session, document_id: str) -> FneDocument | None:
    return db.get(FneDocument, str(document_id))


def get_for_update(db: Session, document_id: str) -> FneDocument | None:
    return db.scalar(select(FneDocument).where(FneDocument.id == str(document_id)).with_for_update())


def sale_for_order(db: Session, order_id: str) -> FneDocument | None:
    return db.scalar(
        select(FneDocument).where(
            FneDocument.order_id == str(order_id), FneDocument.type == FneDocumentType.FNE
        )
    )


def refunds_of(db: Session, parent_id: str) -> list[FneDocument]:
    return list(
        db.scalars(
            select(FneDocument)
            .where(FneDocument.parent_document_id == str(parent_id))
            .order_by(FneDocument.created_at)
        )
    )


from caisse.pagination import PageRequest, newest_first


def next_due(db: Session, now: datetime) -> FneDocument | None:
    """Plus ancien document en file dont le renvoi est échu, verrouillé ; un document déjà pris
    par un autre processus est sauté. Jamais un document incertain."""
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


def list_documents(
    db: Session,
    *,
    status: str | None = None,
    business_date: date | None = None,
    start_date: datetime | None = None,
    page: PageRequest | None = None,
    limit: int | None = None,
) -> list[FneDocument]:
    """Une ligne de plus que la page si page est spécifié (voir `pagination.split`)."""
    if page is not None:
        stmt = newest_first(
            select(FneDocument),
            FneDocument.created_at,
            FneDocument.id,
            page,
        )
    else:
        stmt = select(FneDocument).order_by(FneDocument.created_at.desc(), FneDocument.id.desc()).limit(limit or 200)
    if status is not None:
        stmt = stmt.where(FneDocument.status == status)
    if business_date is not None:
        stmt = (
            stmt.outerjoin(Order, Order.id == FneDocument.order_id)
            .join(
                CashSession,
                or_(
                    CashSession.id == FneDocument.cash_session_id,
                    CashSession.id == Order.cash_session_id,
                ),
            )
            .where(CashSession.business_date == business_date)
        )
    if start_date is not None:
        stmt = stmt.where(FneDocument.created_at >= start_date)
    return list(db.scalars(stmt))


def pending_counts(db: Session, business_date: Optional[date] = None) -> tuple[int, int, int]:
    """(en attente, dont incertains, dont refusés)."""
    stmt = (
        select(
            func.count(),
            func.count().filter(FneDocument.is_uncertain.is_(True)),
            func.count().filter(FneDocument.status == FneStatus.FAILED),
        )
        .where(FneDocument.status.in_(PENDING_STATUSES))
    )
    if business_date is not None:
        stmt = (
            stmt.outerjoin(Order, Order.id == FneDocument.order_id)
            .outerjoin(
                CashSession,
                or_(
                    CashSession.id == FneDocument.cash_session_id,
                    CashSession.id == Order.cash_session_id,
                ),
            )
            .where(
                or_(
                    CashSession.business_date == business_date,
                    func.date(FneDocument.created_at) == business_date,
                    func.date(Order.opened_at) == business_date,
                )
            )
        )
    row = db.execute(stmt).one()
    return int(row[0]), int(row[1]), int(row[2])


def order_numbers(db: Session, order_ids: set[str]) -> dict[str, str]:
    if not order_ids:
        return {}
    clean_ids = [str(oid) for oid in order_ids]
    rows = db.execute(select(Order.id, Order.order_number).where(Order.id.in_(clean_ids)))
    return {str(order_id): number for order_id, number in rows}


def captured_payments(db: Session, order_id: str) -> list[tuple[PaymentMethod, int]]:
    rows = db.execute(
        select(Payment.method, Payment.amount_xof)
        .where(Payment.order_id == str(order_id), Payment.status == "CAPTURED")
        .order_by(Payment.created_at)
    )
    res = []
    for method_str, amount in rows:
        try:
            m = PaymentMethod(method_str)
        except ValueError:
            m = PaymentMethod.CASH
        res.append((m, int(amount)))
    return res


def paid_orders_totals(db: Session, business_date: date) -> tuple[int, int]:
    row = db.execute(
        select(func.count(), func.coalesce(func.sum(Order.total_ttc_xof), 0)).where(
            func.date(Order.opened_at) == business_date, Order.status == OrderStatus.PAID
        )
    ).one()
    return int(row[0]), int(row[1])


def certified_orders_totals(db: Session, business_date: date) -> tuple[int, int]:
    row = db.execute(
        select(func.count(), func.coalesce(func.sum(Order.total_ttc_xof), 0))
        .join(FneDocument, FneDocument.order_id == Order.id)
        .where(
            func.date(Order.opened_at) == business_date,
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
            .where(func.date(Order.opened_at) == business_date, FneDocument.status.in_(PENDING_STATUSES))
        )
        or 0
    )


def fiscal_group_totals(db: Session, business_date: date) -> list[tuple[str, int, int]]:
    rows = db.execute(
        select(
            OrderItem.category_snapshot,
            func.sum(OrderItem.quantity),
            func.sum(OrderItem.line_total_xof),
        )
        .join(Order, Order.id == OrderItem.order_id)
        .where(
            func.date(Order.opened_at) == business_date,
            Order.status == OrderStatus.PAID,
            OrderItem.removed_at.is_(None),
        )
        .group_by(OrderItem.category_snapshot)
        .order_by(OrderItem.category_snapshot)
    )
    return [(group or "DIVERS", int(qty), int(amount)) for group, qty, amount in rows]


class FneRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, fne_id: str) -> Optional[FneDocument]:
        return get(self.db, fne_id)

    def get_by_order_id(self, order_id: str) -> Optional[FneDocument]:
        return sale_for_order(self.db, order_id)

    def list_documents(
        self,
        status: Optional[str] = None,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[FneDocument]:
        q = self.db.query(FneDocument)
        if status:
            q = q.filter(FneDocument.status == status)
        if start_date:
            q = q.filter(FneDocument.created_at >= start_date)
        if end_date:
            q = q.filter(FneDocument.created_at <= end_date)
        return q.order_by(FneDocument.created_at.desc()).limit(limit).offset(offset).all()

    def add(self, doc: FneDocument) -> FneDocument:
        self.db.add(doc)
        self.db.flush()
        return doc
