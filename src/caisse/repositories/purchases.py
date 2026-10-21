import uuid
from collections.abc import Iterable
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import distinct_on
from sqlalchemy.orm import Session

from caisse.domain.enums import PurchaseStatus, StockMovementType
from caisse.models.purchase import PurchaseRequest, PurchaseRequestLine
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.user import User
from caisse.pagination import PageRequest, newest_first


def get(db: Session, request_id: uuid.UUID) -> PurchaseRequest | None:
    return db.get(PurchaseRequest, request_id)


def get_for_update(db: Session, request_id: uuid.UUID) -> PurchaseRequest | None:
    return db.scalar(
        select(PurchaseRequest).where(PurchaseRequest.id == request_id).with_for_update()
    )


def lines(db: Session, request_id: uuid.UUID) -> list[tuple[PurchaseRequestLine, StockArticle]]:
    """Lignes avec leur article, par famille puis par nom (ordre de la liste de courses)."""
    rows = db.execute(
        select(PurchaseRequestLine, StockArticle)
        .join(StockArticle, StockArticle.id == PurchaseRequestLine.article_id)
        .where(PurchaseRequestLine.request_id == request_id)
        .order_by(StockArticle.category, StockArticle.name)
    )
    return [(line, article) for line, article in rows]


def line_counts(db: Session, request_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, int]:
    ids = list(set(request_ids))
    if not ids:
        return {}
    rows = db.execute(
        select(PurchaseRequestLine.request_id, func.count())
        .where(PurchaseRequestLine.request_id.in_(ids))
        .group_by(PurchaseRequestLine.request_id)
    )
    return {request_id: count for request_id, count in rows}


def list_requests(
    db: Session,
    *,
    status: PurchaseStatus | None,
    requested_by: uuid.UUID | None,
    page: PageRequest,
) -> list[PurchaseRequest]:
    """Une ligne de plus que la page (voir `pagination.split`)."""
    stmt = newest_first(
        select(PurchaseRequest), PurchaseRequest.created_at, PurchaseRequest.id, page
    )
    if status is not None:
        stmt = stmt.where(PurchaseRequest.status == status)
    if requested_by is not None:
        stmt = stmt.where(PurchaseRequest.requested_by_user_id == requested_by)
    return list(db.scalars(stmt))


def count_by_status(db: Session) -> dict[PurchaseStatus, int]:
    rows = db.execute(select(PurchaseRequest.status, func.count()).group_by(PurchaseRequest.status))
    return {status: count for status, count in rows}


def last_purchase_costs(db: Session, article_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, Decimal]:
    """Prix d'une unité à la dernière entrée d'achat de chaque article (s'il y en a eu une)."""
    ids = list(set(article_ids))
    if not ids:
        return {}
    rows = db.execute(
        select(StockMovement.article_id, StockMovement.unit_cost_xof)
        .where(
            StockMovement.article_id.in_(ids),
            StockMovement.type == StockMovementType.PURCHASE_IN,
        )
        .order_by(
            StockMovement.article_id, StockMovement.created_at.desc(), StockMovement.id.desc()
        )
        .ext(distinct_on(StockMovement.article_id))
    )
    return {article_id: cost for article_id, cost in rows}


def active_articles(db: Session, article_ids: Iterable[uuid.UUID]) -> list[StockArticle]:
    ids = list(set(article_ids))
    if not ids:
        return []
    return list(
        db.scalars(
            select(StockArticle).where(StockArticle.id.in_(ids), StockArticle.is_active.is_(True))
        )
    )


def users_by_id(db: Session, user_ids: Iterable[uuid.UUID | None]) -> dict[uuid.UUID, User]:
    ids = {i for i in user_ids if i is not None}
    if not ids:
        return {}
    return {user.id: user for user in db.scalars(select(User).where(User.id.in_(ids)))}
