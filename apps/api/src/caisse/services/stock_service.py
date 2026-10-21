"""Stock (01-BACKEND §5.5) : articles, fiches techniques, entrées, pertes, inventaires, et
sortie automatique des plats vendus à l'encaissement.

La quantité d'un article ne change que par un mouvement (`stock_movements`), dans la même
transaction que l'opération qui le cause. Le stock négatif est permis : la vente n'est jamais
bloquée, l'écart apparaît au prochain inventaire et dans le tableau de stock.
"""

from collections.abc import Callable
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Any

from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.domain import stock_rules
from caisse.domain.enums import StockMovementType
from caisse.errors import IdempotencyConflictError, NotFoundError, StockArticleNameExistsError
from caisse.models.catalog import Product
from caisse.models.order import Order
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.models.user import User
from caisse.repositories import orders as orders_repo
from caisse.repositories import stock as stock_repo
from caisse.schemas.common import ApiWarning
from caisse.schemas.stock import (
    ComponentOut,
    ComponentsUpdate,
    ProductComponentsOut,
    StockArticleCreate,
    StockArticleOut,
    StockArticleUpdate,
    StockCountCreate,
    StockLossCreate,
    StockMovementOut,
    StockOperationOut,
    StockReceiptCreate,
)
from caisse.services import audit_service

# champs que `null` ne peut pas effacer
_REQUIRED_FIELDS = {"name", "category", "unit", "out_mode", "is_active"}


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# --- Lecture -----------------------------------------------------------------------------


def article_out(article: StockArticle) -> StockArticleOut:
    return StockArticleOut(
        id=str(article.id),
        name=article.name,
        category=article.category,
        unit=article.unit,
        out_mode=article.out_mode,
        quantity=float(article.quantity),
        avg_cost_xof=float(article.avg_cost_xof),
        value_xof=stock_rules.value_xof(max(article.quantity, Decimal(0)), article.avg_cost_xof),
        alert_threshold=(
            float(article.alert_threshold) if article.alert_threshold is not None else None
        ),
        is_low=stock_rules.is_below_threshold(article.quantity, article.alert_threshold),
        is_active=article.is_active,
        note=article.note,
        updated_at=article.updated_at,
    )


def movement_out(movement: StockMovement, article_name: str) -> StockMovementOut:
    return StockMovementOut(
        id=str(movement.id),
        article_id=str(movement.article_id),
        article_name=article_name,
        type=movement.type,
        quantity=float(movement.quantity),
        quantity_after=float(movement.quantity_after),
        unit_cost_xof=float(movement.unit_cost_xof),
        value_xof=stock_rules.value_xof(movement.quantity, movement.unit_cost_xof),
        business_date=movement.business_date,
        reference_order_id=str(movement.reference_order_id) if movement.reference_order_id else None,
        supplier=movement.supplier,
        reason=movement.reason,
        user_id=str(movement.user_id) if movement.user_id else None,
        created_at=movement.created_at,
    )


def get_article(db: Session, article_id: str) -> StockArticle:
    article = stock_repo.get_article(db, str(article_id))
    if article is None:
        raise NotFoundError(meta={"article_id": str(article_id)})
    return article


def business_day(db: Session, requested: date | None = None) -> date:
    """Journée d'un mouvement : celle demandée, sinon celle de la session ouverte, sinon aujourd'hui."""
    if requested is not None:
        return requested
    from caisse.repositories.sessions import CashSessionRepository
    from caisse.domain.enums import CashSessionStatus
    repo = CashSessionRepository(db)
    active = repo.db.query(repo.model).filter(repo.model.status == "OPEN").first()
    if active and hasattr(active, "business_date"):
        try:
            if isinstance(active.business_date, str):
                return date.fromisoformat(active.business_date)
            return active.business_date
        except Exception:
            pass
    return utcnow().date()


# --- Articles ----------------------------------------------------------------------------


def create_article(
    db: Session, body: StockArticleCreate, *, actor_id: str | None, ctx: Any = None
) -> StockArticle:
    existing = stock_repo.get_by_name(db, body.name)
    if existing is not None:
        raise StockArticleNameExistsError(meta={"article_id": str(existing.id)})
    article = StockArticle(
        name=body.name,
        category=body.category,
        unit=body.unit,
        out_mode=body.out_mode,
        quantity=Decimal(0),
        avg_cost_xof=body.avg_cost_xof,
        alert_threshold=body.alert_threshold,
        is_active=True,
        note=body.note,
    )
    db.add(article)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise StockArticleNameExistsError(meta={"name": body.name}) from None
    audit_service.log(
        db,
        "stock.article_create",
        ctx=ctx,
        user_id=str(actor_id) if actor_id else None,
        entity="stock_article",
        entity_id=str(article.id),
        after=body.model_dump(mode="json"),
    )
    db.commit()
    return article


def update_article(
    db: Session,
    article_id: str,
    body: StockArticleUpdate,
    *,
    actor_id: str | None,
    ctx: Any = None,
) -> StockArticle:
    article = get_article(db, str(article_id))
    changes = {
        key: value
        for key, value in body.model_dump(exclude_unset=True).items()
        if value is not None or key not in _REQUIRED_FIELDS
    }
    new_name = changes.get("name")
    if new_name is not None and new_name.lower() != article.name.lower():
        existing = stock_repo.get_by_name(db, new_name)
        if existing is not None:
            raise StockArticleNameExistsError(meta={"article_id": str(existing.id)})
    before = {key: getattr(article, key) for key in changes}
    for key, value in changes.items():
        setattr(article, key, value)
    audit_service.log(
        db,
        "stock.article_update",
        ctx=ctx,
        user_id=str(actor_id) if actor_id else None,
        entity="stock_article",
        entity_id=str(article.id),
        before={k: str(v) if v is not None else None for k, v in before.items()},
        after={k: str(v) if v is not None else None for k, v in changes.items()},
    )
    db.commit()
    return article


# --- Mouvements --------------------------------------------------------------------------


def move(
    db: Session,
    article: StockArticle,
    movement_type: StockMovementType,
    quantity: Decimal,
    *,
    unit_cost: Decimal,
    business_date: date,
    user_id: str | None,
    order_id: str | None = None,
    order_item_id: str | None = None,
    supplier: str | None = None,
    reason: str | None = None,
) -> StockMovement:
    """Applique un mouvement signé à un article déjà verrouillé. Le coût moyen est mis à jour
    par l'appelant quand il change (entrée, remise en stock)."""
    article.quantity = stock_rules.quantize_qty(article.quantity + quantity)
    movement = StockMovement(
        article_id=str(article.id),
        type=movement_type,
        quantity=stock_rules.quantize_qty(quantity),
        quantity_after=article.quantity,
        unit_cost_xof=stock_rules.quantize_cost(unit_cost),
        business_date=business_date,
        reference_order_id=str(order_id) if order_id else None,
        reference_order_item_id=str(order_item_id) if order_item_id else None,
        supplier=supplier,
        reason=reason,
        user_id=str(user_id) if user_id else None,
        created_at=utcnow(),
    )
    db.add(movement)
    return movement


def _lock_existing(db: Session, article_ids: list[str]) -> dict[str, StockArticle]:
    articles = stock_repo.lock_articles(db, [str(i) for i in article_ids])
    missing = [str(i) for i in article_ids if str(i) not in articles]
    if missing:
        raise NotFoundError(meta={"article_ids": missing})
    return articles


def negative_warnings(articles: list[StockArticle]) -> list[ApiWarning]:
    """`STOCK_NEGATIVE_WARNING` (03-CONTRAT-API §4.6) pour chaque article passé sous zéro."""
    return [
        ApiWarning(
            code="STOCK_NEGATIVE_WARNING",
            detail=f"{a.name} : stock {a.quantity.normalize():f}",
            meta={"article_id": str(a.id), "quantity": float(a.quantity)},
        )
        for a in articles
        if a.quantity < 0
    ]


def _operation_out(
    movements: list[StockMovement], articles: dict[str, StockArticle]
) -> StockOperationOut:
    touched = [articles[str(m.article_id)] for m in movements]
    unique = list({a.id: a for a in touched}.values())
    return StockOperationOut(
        movements=[movement_out(m, articles[str(m.article_id)].name) for m in movements],
        articles=[article_out(a) for a in unique],
        warnings=negative_warnings(unique),
    )


def _run_idempotent(
    db: Session,
    *,
    key: str,
    path: str,
    body: StockReceiptCreate | StockLossCreate | StockCountCreate,
    user: User,
    operation: Callable[[], StockOperationOut],
) -> tuple[StockOperationOut, bool]:
    request_hash = idempotency.hash_request(body)
    replay = idempotency.find_replay(db, key, method="POST", path=path, request_hash=request_hash)
    if replay is not None:
        return StockOperationOut.model_validate(replay), True
    result = operation()
    idempotency.save(
        db,
        key,
        method="POST",
        path=path,
        request_hash=request_hash,
        status=201,
        body=result.model_dump(mode="json"),
        user_id=str(user.id),
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        replay = idempotency.find_replay(
            db, key, method="POST", path=path, request_hash=request_hash
        )
        if replay is None:
            raise IdempotencyConflictError(meta={"key": key}) from None
        return StockOperationOut.model_validate(replay), True
    return result, False


def receive(
    db: Session,
    body: StockReceiptCreate,
    *,
    key: str,
    path: str,
    user: User,
    ctx: Any = None,
) -> tuple[StockOperationOut, bool]:
    """Entrée (achat) : quantité ajoutée, coût moyen pondéré recalculé avec le prix payé."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = _lock_existing(db, [str(line.article_id) for line in body.lines])
        movements: list[StockMovement] = []
        for line in body.lines:
            article = articles[str(line.article_id)]
            if line.unit_cost_xof is not None:
                unit_cost = line.unit_cost_xof
            else:
                unit_cost = Decimal(line.total_cost_xof or 0) / line.quantity
            unit_cost = stock_rules.quantize_cost(unit_cost)
            article.avg_cost_xof = stock_rules.weighted_average_cost(
                article.quantity, article.avg_cost_xof, line.quantity, unit_cost
            )
            movements.append(
                move(
                    db,
                    article,
                    StockMovementType.PURCHASE_IN,
                    line.quantity,
                    unit_cost=unit_cost,
                    business_date=day,
                    user_id=str(user.id),
                    supplier=body.supplier,
                    reason=body.reason,
                )
            )
        db.flush()
        audit_service.log(
            db,
            "stock.receive",
            ctx=ctx,
            user_id=str(user.id),
            entity="stock_movement",
            entity_id=str(movements[0].id),
            after={
                "business_date": str(day),
                "supplier": body.supplier,
                "total_xof": sum(
                    stock_rules.value_xof(m.quantity, m.unit_cost_xof) for m in movements
                ),
                "lines": len(movements),
            },
        )
        return _operation_out(movements, articles)

    return _run_idempotent(db, key=key, path=path, body=body, user=user, operation=operation)


def declare_loss(
    db: Session,
    body: StockLossCreate,
    *,
    key: str,
    path: str,
    user: User,
    ctx: Any = None,
) -> tuple[StockOperationOut, bool]:
    """Perte (avarié, cassé, repas du personnel…), valorisée au coût moyen."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = _lock_existing(db, [str(line.article_id) for line in body.lines])
        movements = [
            move(
                db,
                articles[str(line.article_id)],
                StockMovementType.LOSS_OUT,
                -line.quantity,
                unit_cost=articles[str(line.article_id)].avg_cost_xof,
                business_date=day,
                user_id=str(user.id),
                reason=body.reason,
            )
            for line in body.lines
        ]
        db.flush()
        audit_service.log(
            db,
            "stock.loss",
            ctx=ctx,
            user_id=str(user.id),
            entity="stock_movement",
            entity_id=str(movements[0].id),
            after={"business_date": str(day), "lines": len(movements)},
            reason=body.reason,
        )
        return _operation_out(movements, articles)

    return _run_idempotent(db, key=key, path=path, body=body, user=user, operation=operation)


def count(
    db: Session,
    body: StockCountCreate,
    *,
    key: str,
    path: str,
    user: User,
    ctx: Any = None,
) -> tuple[StockOperationOut, bool]:
    """Inventaire : le stock devient la quantité comptée ; le mouvement porte l'écart."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = _lock_existing(db, [str(line.article_id) for line in body.lines])
        movements = [
            move(
                db,
                articles[str(line.article_id)],
                (
                    StockMovementType.INVENTORY_COUNT
                    if stock_repo.has_movements(db, str(line.article_id))
                    else StockMovementType.OPENING
                ),
                line.counted_quantity - articles[str(line.article_id)].quantity,
                unit_cost=articles[str(line.article_id)].avg_cost_xof,
                business_date=day,
                user_id=str(user.id),
                reason=body.reason,
            )
            for line in body.lines
        ]
        db.flush()
        audit_service.log(
            db,
            "stock.count",
            ctx=ctx,
            user_id=str(user.id),
            entity="stock_movement",
            entity_id=str(movements[0].id),
            after={
                "business_date": str(day),
                "lines": len(movements),
                "variance_xof": sum(
                    stock_rules.value_xof(m.quantity, m.unit_cost_xof) for m in movements
                ),
            },
        )
        return _operation_out(movements, articles)

    return _run_idempotent(db, key=key, path=path, body=body, user=user, operation=operation)


# --- Ventes ------------------------------------------------------------------------------


def _sale_balance(
    movements: list[StockMovement],
) -> dict[tuple[str | None, str], tuple[Decimal, Decimal]]:
    """(ligne, article) → (quantité nette sortie, coût de la sortie)."""
    balance: dict[tuple[str | None, str], tuple[Decimal, Decimal]] = {}
    for m in movements:
        key = (str(m.reference_order_item_id) if m.reference_order_item_id else None, str(m.article_id))
        net, cost = balance.get(key, (Decimal(0), m.unit_cost_xof))
        if m.type == StockMovementType.SALE_OUT:
            cost = m.unit_cost_xof
        balance[key] = (net + m.quantity, cost)
    return balance


def apply_sale(db: Session, order: Order, user_id: str) -> list[ApiWarning]:
    """Commande soldée : chaque ligne déstocke les articles de sa fiche technique, au coût
    moyen du moment. Sans effet si la vente est déjà déstockée. Retourne un avertissement
    par article passé sous zéro (la vente n'est jamais bloquée)."""
    balance = _sale_balance(stock_repo.sale_movements(db, str(order.id)))
    if any(net != 0 for net, _ in balance.values()):
        return []
    items = orders_repo.active_items(db, str(order.id))
    recipes = stock_repo.components_by_product(db, [str(item.product_id) for item in items])
    article_ids = [str(article.id) for recipe in recipes.values() for _, article in recipe]
    if not article_ids:
        return []
    articles = stock_repo.lock_articles(db, article_ids)
    
    # Résolution de la journée comptable de la commande
    order_date = order.business_date if hasattr(order, "business_date") and order.business_date else business_day(db)
    if isinstance(order_date, str):
        try:
            order_date = date.fromisoformat(order_date)
        except Exception:
            order_date = business_day(db)

    for item in items:
        for per_portion, recipe_article in recipes.get(str(item.product_id), []):
            article = articles[str(recipe_article.id)]
            move(
                db,
                article,
                StockMovementType.SALE_OUT,
                -(per_portion * Decimal(item.quantity)),
                unit_cost=article.avg_cost_xof,
                business_date=order_date,
                user_id=str(user_id),
                order_id=str(order.id),
                order_item_id=str(item.id),
            )
    return negative_warnings(list(articles.values()))


def reverse_sale(db: Session, order: Order, user_id: str) -> None:
    """La commande n'est plus soldée (paiement annulé) : ce qui était sorti revient en stock,
    au coût de la sortie."""
    balance = _sale_balance(stock_repo.sale_movements(db, str(order.id)))
    article_ids = [article_id for _, article_id in balance]
    if not article_ids:
        return
    articles = stock_repo.lock_articles(db, article_ids)
    
    order_date = order.business_date if hasattr(order, "business_date") and order.business_date else business_day(db)
    if isinstance(order_date, str):
        try:
            order_date = date.fromisoformat(order_date)
        except Exception:
            order_date = business_day(db)

    for (item_id, article_id), (net, cost) in balance.items():
        if net >= 0:
            continue
        article = articles[article_id]
        article.avg_cost_xof = stock_rules.weighted_average_cost(
            article.quantity, article.avg_cost_xof, -net, cost
        )
        move(
            db,
            article,
            StockMovementType.RETURN_IN,
            -net,
            unit_cost=cost,
            business_date=order_date,
            user_id=str(user_id),
            order_id=str(order.id),
            order_item_id=str(item_id) if item_id else None,
            reason="Paiement annulé",
        )


# --- Fiches techniques -------------------------------------------------------------------


def _product(db: Session, product_id: str) -> Product:
    product = db.get(Product, str(product_id))
    if product is None:
        raise NotFoundError(meta={"product_id": str(product_id)})
    return product


def components_out(db: Session, product_id: str) -> ProductComponentsOut:
    product = _product(db, product_id)
    lines = [
        ComponentOut(
            article_id=str(article.id),
            article_name=article.name,
            unit=article.unit,
            quantity=float(component.quantity),
            unit_cost_xof=float(article.avg_cost_xof),
            cost_xof=float(stock_rules.quantize_cost(component.quantity * article.avg_cost_xof)),
        )
        for component, article in stock_repo.components(db, str(product_id))
    ]
    cost = round(sum(line.cost_xof for line in lines), 2)
    return ProductComponentsOut(
        product_id=str(product.id),
        product_name=product.name,
        price_xof=product.price_xof,
        components=lines,
        cost_xof=cost,
        margin_xof=round(product.price_xof - cost, 2),
    )


def set_components(
    db: Session,
    product_id: str,
    body: ComponentsUpdate,
    *,
    actor_id: str | None,
    ctx: Any = None,
) -> ProductComponentsOut:
    """Remplace la fiche technique complète du plat."""
    product = _product(db, product_id)
    for line in body.components:
        get_article(db, str(line.article_id))
    before = [
        {"article_id": str(c.article_id), "quantity": str(c.quantity)}
        for c, _ in stock_repo.components(db, str(product.id))
    ]
    db.execute(delete(ProductComponent).where(ProductComponent.product_id == str(product.id)))
    for line in body.components:
        db.add(
            ProductComponent(
                product_id=str(product.id),
                article_id=str(line.article_id),
                quantity=line.quantity,
            )
        )
    audit_service.log(
        db,
        "stock.components_set",
        ctx=ctx,
        user_id=str(actor_id) if actor_id else None,
        entity="product",
        entity_id=str(product.id),
        before={"components": before},
        after={
            "components": [
                {"article_id": str(c.article_id), "quantity": str(c.quantity)}
                for c in body.components
            ]
        },
    )
    db.commit()
    return components_out(db, str(product.id))


# --- Classe rétrocompatible ---
class StockService:
    def __init__(self, db: Session):
        self.db = db

    def record_sale_out_for_order(self, order: Order, user_id: str) -> None:
        apply_sale(self.db, order, user_id)
