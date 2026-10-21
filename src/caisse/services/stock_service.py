"""Stock (01-BACKEND §5.5) : articles, fiches techniques, entrées, pertes, inventaires, et
sortie automatique des plats vendus à l'encaissement.

La quantité d'un article ne change que par un mouvement (`stock_movements`), dans la même
transaction que l'opération qui le cause. Le stock négatif est permis : la vente n'est jamais
bloquée, l'écart apparaît au prochain inventaire et dans le tableau de stock.
"""

import uuid
from collections.abc import Callable
from datetime import date
from decimal import Decimal

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
from caisse.security import utcnow
from caisse.services import audit_service, auth_service
from caisse.services.audit_service import RequestContext

# champs que `null` ne peut pas effacer
_REQUIRED_FIELDS = {"name", "category", "unit", "out_mode", "is_active"}


# --- Lecture -----------------------------------------------------------------------------


def article_out(article: StockArticle) -> StockArticleOut:
    return StockArticleOut(
        id=article.id,
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
        id=movement.id,
        article_id=movement.article_id,
        article_name=article_name,
        type=movement.type,
        quantity=float(movement.quantity),
        quantity_after=float(movement.quantity_after),
        unit_cost_xof=float(movement.unit_cost_xof),
        value_xof=stock_rules.value_xof(movement.quantity, movement.unit_cost_xof),
        business_date=movement.business_date,
        reference_order_id=movement.reference_order_id,
        supplier=movement.supplier,
        reason=movement.reason,
        user_id=movement.user_id,
        created_at=movement.created_at,
    )


def get_article(db: Session, article_id: uuid.UUID) -> StockArticle:
    article = stock_repo.get_article(db, article_id)
    if article is None:
        raise NotFoundError(meta={"article_id": str(article_id)})
    return article


def business_day(db: Session, requested: date | None = None) -> date:
    """Journée d'un mouvement : celle demandée, sinon celle de la session ouverte, sinon
    aujourd'hui (Abidjan est à UTC)."""
    if requested is not None:
        return requested
    session = auth_service.current_open_session(db)
    return session.business_date if session is not None else utcnow().date()


# --- Articles ----------------------------------------------------------------------------


def create_article(
    db: Session, body: StockArticleCreate, *, actor_id: uuid.UUID, ctx: RequestContext
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
        user_id=actor_id,
        entity="stock_article",
        entity_id=article.id,
        after=body.model_dump(mode="json"),
    )
    db.commit()
    return article


def update_article(
    db: Session,
    article_id: uuid.UUID,
    body: StockArticleUpdate,
    *,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> StockArticle:
    article = get_article(db, article_id)
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
        user_id=actor_id,
        entity="stock_article",
        entity_id=article.id,
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
    user_id: uuid.UUID | None,
    order_id: uuid.UUID | None = None,
    order_item_id: uuid.UUID | None = None,
    supplier: str | None = None,
    reason: str | None = None,
) -> StockMovement:
    """Applique un mouvement signé à un article déjà verrouillé. Le coût moyen est mis à jour
    par l'appelant quand il change (entrée, remise en stock)."""
    article.quantity = stock_rules.quantize_qty(article.quantity + quantity)
    movement = StockMovement(
        article_id=article.id,
        type=movement_type,
        quantity=stock_rules.quantize_qty(quantity),
        quantity_after=article.quantity,
        unit_cost_xof=stock_rules.quantize_cost(unit_cost),
        business_date=business_date,
        reference_order_id=order_id,
        reference_order_item_id=order_item_id,
        supplier=supplier,
        reason=reason,
        user_id=user_id,
        created_at=utcnow(),
    )
    db.add(movement)
    return movement


def record_purchase(
    db: Session,
    article: StockArticle,
    quantity: Decimal,
    unit_cost: Decimal,
    *,
    business_date: date,
    user_id: uuid.UUID,
    supplier: str | None,
    reason: str | None,
) -> StockMovement:
    """Entrée d'achat sur un article verrouillé : coût moyen pondéré recalculé avec le prix
    payé. Sert à `receive` et à la réception d'une demande d'achat."""
    unit_cost = stock_rules.quantize_cost(unit_cost)
    article.avg_cost_xof = stock_rules.weighted_average_cost(
        article.quantity, article.avg_cost_xof, quantity, unit_cost
    )
    return move(
        db,
        article,
        StockMovementType.PURCHASE_IN,
        quantity,
        unit_cost=unit_cost,
        business_date=business_date,
        user_id=user_id,
        supplier=supplier,
        reason=reason,
    )


def lock_existing(db: Session, article_ids: list[uuid.UUID]) -> dict[uuid.UUID, StockArticle]:
    articles = stock_repo.lock_articles(db, article_ids)
    missing = [str(i) for i in article_ids if i not in articles]
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
    movements: list[StockMovement], articles: dict[uuid.UUID, StockArticle]
) -> StockOperationOut:
    touched = [articles[m.article_id] for m in movements]
    unique = list({a.id: a for a in touched}.values())
    return StockOperationOut(
        movements=[movement_out(m, articles[m.article_id].name) for m in movements],
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
    """Une saisie rejouée (double clic, réseau coupé) renvoie la réponse d'origine sans
    second mouvement. Retourne (résultat, rejoué)."""
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
        user_id=user.id,
    )
    try:
        db.commit()
    except IntegrityError:
        # même clé envoyée deux fois en parallèle : la première transaction a gagné
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
    ctx: RequestContext,
) -> tuple[StockOperationOut, bool]:
    """Entrée (achat) : quantité ajoutée, coût moyen pondéré recalculé avec le prix payé."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = lock_existing(db, [line.article_id for line in body.lines])
        movements: list[StockMovement] = []
        for line in body.lines:
            if line.unit_cost_xof is not None:
                unit_cost = line.unit_cost_xof
            else:
                unit_cost = Decimal(line.total_cost_xof or 0) / line.quantity
            movements.append(
                record_purchase(
                    db,
                    articles[line.article_id],
                    line.quantity,
                    unit_cost,
                    business_date=day,
                    user_id=user.id,
                    supplier=body.supplier,
                    reason=body.reason,
                )
            )
        db.flush()
        audit_service.log(
            db,
            "stock.receive",
            ctx=ctx,
            user_id=user.id,
            entity="stock_movement",
            entity_id=movements[0].id,
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
    ctx: RequestContext,
) -> tuple[StockOperationOut, bool]:
    """Perte (avarié, cassé, repas du personnel…), valorisée au coût moyen."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = lock_existing(db, [line.article_id for line in body.lines])
        movements = [
            move(
                db,
                articles[line.article_id],
                StockMovementType.LOSS_OUT,
                -line.quantity,
                unit_cost=articles[line.article_id].avg_cost_xof,
                business_date=day,
                user_id=user.id,
                reason=body.reason,
            )
            for line in body.lines
        ]
        db.flush()
        audit_service.log(
            db,
            "stock.loss",
            ctx=ctx,
            user_id=user.id,
            entity="stock_movement",
            entity_id=movements[0].id,
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
    ctx: RequestContext,
) -> tuple[StockOperationOut, bool]:
    """Inventaire : le stock devient la quantité comptée ; le mouvement porte l'écart
    (perte ou vol pour un article à fiche, consommation pour un article d'inventaire).
    Un écart nul est enregistré aussi : il date le dernier comptage. Le premier comptage
    d'un article sans aucun mouvement est son stock de départ (`OPENING`), pas un écart."""

    def operation() -> StockOperationOut:
        day = business_day(db, body.business_date)
        articles = lock_existing(db, [line.article_id for line in body.lines])
        movements = [
            move(
                db,
                articles[line.article_id],
                (
                    StockMovementType.INVENTORY_COUNT
                    if stock_repo.has_movements(db, line.article_id)
                    else StockMovementType.OPENING
                ),
                line.counted_quantity - articles[line.article_id].quantity,
                unit_cost=articles[line.article_id].avg_cost_xof,
                business_date=day,
                user_id=user.id,
                reason=body.reason,
            )
            for line in body.lines
        ]
        db.flush()
        audit_service.log(
            db,
            "stock.count",
            ctx=ctx,
            user_id=user.id,
            entity="stock_movement",
            entity_id=movements[0].id,
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
) -> dict[tuple[uuid.UUID | None, uuid.UUID], tuple[Decimal, Decimal]]:
    """(ligne, article) → (quantité nette sortie, coût de la sortie)."""
    balance: dict[tuple[uuid.UUID | None, uuid.UUID], tuple[Decimal, Decimal]] = {}
    for m in movements:
        key = (m.reference_order_item_id, m.article_id)
        net, cost = balance.get(key, (Decimal(0), m.unit_cost_xof))
        if m.type == StockMovementType.SALE_OUT:
            cost = m.unit_cost_xof
        balance[key] = (net + m.quantity, cost)
    return balance


def apply_sale(db: Session, order: Order, user_id: uuid.UUID) -> list[ApiWarning]:
    """Commande soldée : chaque ligne déstocke les articles de sa fiche technique, au coût
    moyen du moment. Sans effet si la vente est déjà déstockée. Retourne un avertissement
    par article passé sous zéro (la vente n'est jamais bloquée)."""
    balance = _sale_balance(stock_repo.sale_movements(db, order.id))
    if any(net != 0 for net, _ in balance.values()):
        return []
    items = orders_repo.active_items(db, order.id)
    recipes = stock_repo.components_by_product(db, [item.product_id for item in items])
    articles = stock_repo.lock_articles(
        db, [article.id for recipe in recipes.values() for _, article in recipe]
    )
    for item in items:
        for per_portion, recipe_article in recipes.get(item.product_id, []):
            article = articles[recipe_article.id]
            move(
                db,
                article,
                StockMovementType.SALE_OUT,
                -(per_portion * item.quantity),
                unit_cost=article.avg_cost_xof,
                business_date=order.business_date,
                user_id=user_id,
                order_id=order.id,
                order_item_id=item.id,
            )
    return negative_warnings(list(articles.values()))


def reverse_sale(db: Session, order: Order, user_id: uuid.UUID) -> None:
    """La commande n'est plus soldée (paiement annulé) : ce qui était sorti revient en stock,
    au coût de la sortie."""
    balance = _sale_balance(stock_repo.sale_movements(db, order.id))
    articles = stock_repo.lock_articles(db, [article_id for _, article_id in balance])
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
            business_date=order.business_date,
            user_id=user_id,
            order_id=order.id,
            order_item_id=item_id,
            reason="Paiement annulé",
        )


# --- Fiches techniques -------------------------------------------------------------------


def _product(db: Session, product_id: uuid.UUID) -> Product:
    product = db.get(Product, product_id)
    if product is None:
        raise NotFoundError(meta={"product_id": str(product_id)})
    return product


def components_out(db: Session, product_id: uuid.UUID) -> ProductComponentsOut:
    product = _product(db, product_id)
    lines = [
        ComponentOut(
            article_id=article.id,
            article_name=article.name,
            unit=article.unit,
            quantity=float(component.quantity),
            unit_cost_xof=float(article.avg_cost_xof),
            cost_xof=float(stock_rules.quantize_cost(component.quantity * article.avg_cost_xof)),
        )
        for component, article in stock_repo.components(db, product_id)
    ]
    cost = round(sum(line.cost_xof for line in lines), 2)
    return ProductComponentsOut(
        product_id=product.id,
        product_name=product.name,
        price_xof=product.price_xof,
        components=lines,
        cost_xof=cost,
        margin_xof=round(product.price_xof - cost, 2),
    )


def set_components(
    db: Session,
    product_id: uuid.UUID,
    body: ComponentsUpdate,
    *,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> ProductComponentsOut:
    """Remplace la fiche technique complète du plat. Les ventes déjà déstockées gardent
    leurs mouvements : la nouvelle fiche vaut pour les encaissements suivants."""
    product = _product(db, product_id)
    for line in body.components:
        get_article(db, line.article_id)
    before = [
        {"article_id": str(c.article_id), "quantity": str(c.quantity)}
        for c, _ in stock_repo.components(db, product.id)
    ]
    db.execute(delete(ProductComponent).where(ProductComponent.product_id == product.id))
    for line in body.components:
        db.add(
            ProductComponent(
                product_id=product.id, article_id=line.article_id, quantity=line.quantity
            )
        )
    audit_service.log(
        db,
        "stock.components_set",
        ctx=ctx,
        user_id=actor_id,
        entity="product",
        entity_id=product.id,
        before={"components": before},
        after={
            "components": [
                {"article_id": str(c.article_id), "quantity": str(c.quantity)}
                for c in body.components
            ]
        },
    )
    db.commit()
    return components_out(db, product.id)
