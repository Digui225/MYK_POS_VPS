from collections.abc import Iterable
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import PurchaseStatus, StockMovementType
from caisse.models.purchase import PurchaseRequest, PurchaseRequestLine
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.user import User
from caisse.pagination import PageRequest, newest_first


def get(db: Session, request_id: str) -> PurchaseRequest | None:
    return db.get(PurchaseRequest, request_id)


def get_for_update(db: Session, request_id: str) -> PurchaseRequest | None:
    stmt = select(PurchaseRequest).where(PurchaseRequest.id == request_id)
    bind = db.get_bind()
    if bind is not None and bind.dialect.name == "postgresql":
        stmt = stmt.with_for_update()
    return db.scalar(stmt)


def lines(db: Session, request_id: str) -> list[tuple[PurchaseRequestLine, StockArticle]]:
    """Lignes avec leur article, par famille puis par nom (ordre de la liste de courses)."""
    rows = db.execute(
        select(PurchaseRequestLine, StockArticle)
        .join(StockArticle, StockArticle.id == PurchaseRequestLine.article_id)
        .where(PurchaseRequestLine.request_id == request_id)
        .order_by(StockArticle.category, StockArticle.name)
    )
    return [(line, article) for line, article in rows]


def line_counts(db: Session, request_ids: Iterable[str]) -> dict[str, int]:
    ids = list(set(request_ids))
    if not ids:
        return {}
    rows = db.execute(
        select(PurchaseRequestLine.request_id, func.count())
        .where(PurchaseRequestLine.request_id.in_(ids))
        .group_by(PurchaseRequestLine.request_id)
    )
    return {str(request_id): count for request_id, count in rows}


def list_requests(
    db: Session,
    *,
    status: PurchaseStatus | None,
    requested_by: str | None,
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
    return {PurchaseStatus(status) if isinstance(status, str) else status: count for status, count in rows}


def last_purchase_costs(db: Session, article_ids: Iterable[str]) -> dict[str, Decimal]:
    """Prix d'une unité à la dernière entrée d'achat de chaque article (s'il y en a eu une)."""
    ids = list(set(article_ids))
    if not ids:
        return {}
    bind = db.get_bind()
    if bind is not None and bind.dialect.name == "postgresql":
        from sqlalchemy.dialects.postgresql import distinct_on

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
        return {str(article_id): cost for article_id, cost in rows}
    else:
        rows = db.execute(
            select(StockMovement.article_id, StockMovement.unit_cost_xof)
            .where(
                StockMovement.article_id.in_(ids),
                StockMovement.type == StockMovementType.PURCHASE_IN,
            )
            .order_by(StockMovement.created_at.desc(), StockMovement.id.desc())
        )
        res: dict[str, Decimal] = {}
        for aid, cost in rows:
            if str(aid) not in res:
                res[str(aid)] = cost
        return res


def active_articles(db: Session, article_ids: Iterable[str]) -> list[StockArticle]:
    ids = list(set(article_ids))
    if not ids:
        return []
    return list(
        db.scalars(
            select(StockArticle).where(StockArticle.id.in_(ids), StockArticle.is_active.is_(True))
        )
    )


def users_by_id(db: Session, user_ids: Iterable[str | None]) -> dict[str, User]:
    ids = {str(i) for i in user_ids if i is not None}
    if not ids:
        return {}
    return {str(user.id): user for user in db.scalars(select(User).where(User.id.in_(ids)))}
