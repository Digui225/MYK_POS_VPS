from collections import defaultdict
from collections.abc import Iterable
from datetime import date
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import StockArticleCategory, StockMovementType
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.pagination import PageRequest, newest_first

SALE_TYPES = (StockMovementType.SALE_OUT, StockMovementType.RETURN_IN)


def get_article(db: Session, article_id: str) -> StockArticle | None:
    return db.get(StockArticle, article_id)


def get_by_name(db: Session, name: str) -> StockArticle | None:
    return db.scalar(select(StockArticle).where(func.lower(StockArticle.name) == name.lower()))


def lock_articles(db: Session, article_ids: Iterable[str]) -> dict[str, StockArticle]:
    """Verrou sur les articles, toujours dans le même ordre (pas d'interblocage entre deux
    encaissements qui touchent les mêmes articles)."""
    ids = sorted(set(article_ids))
    if not ids:
        return {}
    rows = db.scalars(
        select(StockArticle)
        .where(StockArticle.id.in_(ids))
        .order_by(StockArticle.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    return {a.id: a for a in rows}


def list_articles(
    db: Session,
    *,
    category: StockArticleCategory | None = None,
    search: str | None = None,
    is_active: bool | None = True,
) -> list[StockArticle]:
    stmt = select(StockArticle).order_by(StockArticle.category, StockArticle.name)
    if category is not None:
        stmt = stmt.where(StockArticle.category == category)
    if search:
        stmt = stmt.where(StockArticle.name.ilike(f"%{search}%"))
    if is_active is not None:
        stmt = stmt.where(StockArticle.is_active.is_(is_active))
    return list(db.scalars(stmt))


def components(db: Session, product_id: str) -> list[tuple[ProductComponent, StockArticle]]:
    rows = db.execute(
        select(ProductComponent, StockArticle)
        .join(StockArticle, StockArticle.id == ProductComponent.article_id)
        .where(ProductComponent.product_id == product_id)
        .order_by(StockArticle.name)
    )
    return [(c, a) for c, a in rows]


def components_by_product(
    db: Session, product_ids: Iterable[str]
) -> dict[str, list[tuple[Decimal, StockArticle]]]:
    """Fiche technique de chaque produit : [(quantité par portion, article)]."""
    ids = list(set(product_ids))
    result: dict[str, list[tuple[Decimal, StockArticle]]] = defaultdict(list)
    if not ids:
        return result
    rows = db.execute(
        select(ProductComponent.product_id, ProductComponent.quantity, StockArticle)
        .join(StockArticle, StockArticle.id == ProductComponent.article_id)
        .where(ProductComponent.product_id.in_(ids))
    )
    for product_id, quantity, article in rows:
        result[product_id].append((quantity, article))
    return result


def has_movements(db: Session, article_id: str) -> bool:
    return (
        db.scalar(select(StockMovement.id).where(StockMovement.article_id == article_id).limit(1))
        is not None
    )


def sale_movements(db: Session, order_id: str) -> list[StockMovement]:
    return list(
        db.scalars(
            select(StockMovement)
            .where(StockMovement.reference_order_id == order_id, StockMovement.type.in_(SALE_TYPES))
            .order_by(StockMovement.created_at, StockMovement.id)
        )
    )


def list_movements(
    db: Session,
    *,
    article_id: str | None = None,
    movement_type: StockMovementType | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    page: PageRequest | None = None,
    limit: int | None = None,
) -> list[tuple[StockMovement, str]]:
    """Une ligne de plus que la page (voir `pagination.split`)."""
    if page is not None:
        stmt = newest_first(
            select(StockMovement, StockArticle.name).join(
                StockArticle, StockArticle.id == StockMovement.article_id
            ),
            StockMovement.created_at,
            StockMovement.id,
            page,
        )
    else:
        stmt = (
            select(StockMovement, StockArticle.name)
            .join(StockArticle, StockArticle.id == StockMovement.article_id)
            .order_by(StockMovement.created_at.desc(), StockMovement.id.desc())
            .limit(limit or 100)
        )
    if article_id is not None:
        stmt = stmt.where(StockMovement.article_id == article_id)
    if movement_type is not None:
        stmt = stmt.where(StockMovement.type == movement_type)
    if date_from is not None:
        stmt = stmt.where(StockMovement.business_date >= date_from)
    if date_to is not None:
        stmt = stmt.where(StockMovement.business_date <= date_to)
    return [(m, name) for m, name in db.execute(stmt)]


# Classe de compatibilité
class StockRepository:
    def __init__(self, db: Session):
        self.db = db

    def list_items(self) -> list[StockArticle]:
        return list_articles(self.db)

