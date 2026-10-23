from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Path, Query, Request, Response, status

from caisse.deps import Ctx, CurrentUser, DbSession, Paging, Responsable
from caisse.domain.enums import StockArticleCategory, StockMovementType
from caisse.domain.stock_rules import is_below_threshold
from caisse.idempotency import IdempotencyKey
from caisse.pagination import split
from caisse.repositories import stock as stock_repo
from caisse.schemas.common import Page
from caisse.schemas.stock import (
    ComponentsUpdate,
    ProductComponentsOut,
    StockArticleCreate,
    StockArticleOut,
    StockArticleUpdate,
    StockCountCreate,
    StockItemResponse,
    StockLossCreate,
    StockMovementOut,
    StockMovementRequest,
    StockMovementResponse,
    StockOperationOut,
    StockReceiptCreate,
)
from caisse.services import stock_service

router = APIRouter(tags=["Stock"])

ArticleId = Annotated[str, Path(description="Identifiant de l'article de stock")]
ProductId = Annotated[str, Path(description="Identifiant du produit (plat ou boisson)")]

_OPERATION_ERRORS = """
Idempotent (`Idempotency-Key` obligatoire) : un rejeu renvoie la réponse d'origine en `200`
avec `Idempotent-Replay: true`, sans second mouvement.

Warning `STOCK_NEGATIVE_WARNING` (`meta.article_id`, `meta.quantity`) si un article passe
sous zéro : rien n'est bloqué.

Erreurs : `404 NOT_FOUND` (`meta.article_ids` : articles inconnus), `409 IDEMPOTENCY_CONFLICT`,
`422 VALIDATION_ERROR` (article présent deux fois, quantité ≤ 0…).
"""


def _send(response: Response, result: StockOperationOut, replayed: bool) -> StockOperationOut:
    if replayed:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replay"] = "true"
    return result


# --- Articles ----------------------------------------------------------------------------


@router.get("/stock/articles", response_model=Page[StockArticleOut], summary="Lister les articles")
def list_articles(
    _: Responsable,
    db: DbSession,
    category: Annotated[StockArticleCategory | None, Query(description="Famille")] = None,
    search: Annotated[str | None, Query(max_length=80, description="Nom (contient)")] = None,
    is_active: Annotated[
        bool | None, Query(description="true (défaut) : utilisés ; false : désactivés")
    ] = True,
    low_only: Annotated[bool, Query(description="Seulement les articles en alerte")] = False,
) -> Page[StockArticleOut]:
    """Articles par famille puis par nom, avec quantité, coût moyen, valeur et alerte
    (`is_low` : stock négatif ou au plus égal au seuil)."""
    articles = stock_repo.list_articles(db, category=category, search=search, is_active=is_active)
    if low_only:
        articles = [a for a in articles if is_below_threshold(a.quantity, a.alert_threshold)]
    return Page(items=[stock_service.article_out(a) for a in articles])


@router.post(
    "/stock/articles",
    response_model=StockArticleOut,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un article",
)
def create_article(
    body: StockArticleCreate, user: Responsable, db: DbSession, ctx: Ctx
) -> StockArticleOut:
    """L'article est créé à 0 : le stock de départ se saisit par un inventaire
    (`POST /stock/counts`) ou une entrée (`POST /stock/receipts`).

    Erreurs : `409 STOCK_ARTICLE_NAME_EXISTS` (`meta.article_id`), `422 VALIDATION_ERROR`.
    """
    article = stock_service.create_article(db, body, actor_id=user.id, ctx=ctx)
    return stock_service.article_out(article)


@router.get(
    "/stock/articles/{article_id}", response_model=StockArticleOut, summary="Détail d'un article"
)
def get_article(article_id: ArticleId, _: Responsable, db: DbSession) -> StockArticleOut:
    """Erreurs : `404 NOT_FOUND`."""
    return stock_service.article_out(stock_service.get_article(db, article_id))


@router.patch(
    "/stock/articles/{article_id}", response_model=StockArticleOut, summary="Modifier un article"
)
def update_article(
    article_id: ArticleId, body: StockArticleUpdate, user: Responsable, db: DbSession, ctx: Ctx
) -> StockArticleOut:
    """Seuls les champs envoyés changent ; `alert_threshold: null` retire l'alerte."""
    article = stock_service.update_article(db, article_id, body, actor_id=user.id, ctx=ctx)
    return stock_service.article_out(article)


# --- Saisies -----------------------------------------------------------------------------


@router.post(
    "/stock/receipts",
    response_model=StockOperationOut,
    status_code=status.HTTP_201_CREATED,
    summary="Entrée de stock (achat)",
)
def receive(
    body: StockReceiptCreate,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> StockOperationOut:
    """Une ligne par article reçu, avec le montant payé (`total_cost_xof`) ou le prix d'une unité (`unit_cost_xof`)."""
    result, replayed = stock_service.receive(
        db, body, key=idempotency_key, path=request.url.path, user=user, ctx=ctx
    )
    return _send(response, result, replayed)


@router.post(
    "/stock/losses",
    response_model=StockOperationOut,
    status_code=status.HTTP_201_CREATED,
    summary="Déclarer une perte",
)
def declare_loss(
    body: StockLossCreate,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> StockOperationOut:
    """Avarié, cassé, repas du personnel… Motif obligatoire ; valorisé au coût moyen."""
    result, replayed = stock_service.declare_loss(
        db, body, key=idempotency_key, path=request.url.path, user=user, ctx=ctx
    )
    return _send(response, result, replayed)


@router.post(
    "/stock/counts",
    response_model=StockOperationOut,
    status_code=status.HTTP_201_CREATED,
    summary="Saisir un inventaire",
)
def count(
    body: StockCountCreate,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> StockOperationOut:
    """Quantités réellement présentes : le stock de chaque article devient la quantité comptée."""
    result, replayed = stock_service.count(
        db, body, key=idempotency_key, path=request.url.path, user=user, ctx=ctx
    )
    return _send(response, result, replayed)


@router.get(
    "/stock/movements", response_model=Page[StockMovementOut], summary="Journal des mouvements"
)
def list_movements(
    _: Responsable,
    db: DbSession,
    page: Paging,
    article_id: Annotated[str | None, Query(description="Un seul article")] = None,
    type: Annotated[StockMovementType | None, Query(description="Nature du mouvement")] = None,
    date_from: Annotated[date | None, Query(description="Journée de début (incluse)")] = None,
    date_to: Annotated[date | None, Query(description="Journée de fin (incluse)")] = None,
) -> Page[StockMovementOut]:
    """Du plus récent au plus ancien, par pages de `limit` : `next_cursor` donne la suivante."""
    rows = stock_repo.list_movements(
        db,
        article_id=article_id,
        movement_type=type,
        date_from=date_from,
        date_to=date_to,
        page=page,
    )
    movements, next_cursor = split(rows, page, lambda row: (row[0].created_at, row[0].id))
    return Page(
        items=[stock_service.movement_out(m, name) for m, name in movements],
        next_cursor=next_cursor,
    )


# --- Fiches techniques -------------------------------------------------------------------


@router.get(
    "/products/{product_id}/components",
    response_model=ProductComponentsOut,
    summary="Fiche technique d'un plat",
)
def get_components(product_id: ProductId, _: Responsable, db: DbSession) -> ProductComponentsOut:
    """Articles consommés par une portion, coût matière au coût moyen actuel et marge."""
    return stock_service.components_out(db, product_id)


@router.put(
    "/products/{product_id}/components",
    response_model=ProductComponentsOut,
    summary="Remplacer la fiche technique d'un plat",
)
def set_components(
    product_id: ProductId, body: ComponentsUpdate, user: Responsable, db: DbSession, ctx: Ctx
) -> ProductComponentsOut:
    """Fiche complète ; `components: []` : le plat ne déstocke plus."""
    return stock_service.set_components(db, product_id, body, actor_id=user.id, ctx=ctx)


# --- Rétrocompatibilité ancien format ---


@router.get("/stock", response_model=list[StockItemResponse], summary="Lister l'état des stocks (rétrocompatibilité)")
def list_stock_legacy(_: CurrentUser, db: DbSession) -> list[StockItemResponse]:
    articles = stock_repo.list_articles(db)
    return [stock_service.article_out(a) for a in articles]
