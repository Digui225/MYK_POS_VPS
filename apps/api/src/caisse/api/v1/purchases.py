from typing import Annotated

from fastapi import APIRouter, Path, Query, Request, Response, status

from caisse.deps import Acheteur, Ctx, CurrentUser, DbSession, Paging, Responsable
from caisse.domain.enums import PurchaseStatus, StockArticleCategory
from caisse.idempotency import IdempotencyKey
from caisse.pagination import split
from caisse.repositories import purchases as purchases_repo
from caisse.schemas.common import Page
from caisse.schemas.production import MarketBudgetStatusOut
from caisse.schemas.purchases import (
    BuyerPurchaseOut,
    BuyerPurchaseSummaryOut,
    PurchaseApprove,
    PurchaseArticleOut,
    PurchaseCancel,
    PurchaseCreate,
    PurchaseDisburse,
    PurchaseOut,
    PurchasePendingOut,
    PurchaseReceive,
    PurchaseReject,
    PurchaseSummaryOut,
)
from caisse.services import purchase_service

router = APIRouter(prefix="/purchases", tags=["Approvisionnement"])

PurchaseId = Annotated[str, Path(description="Identifiant de la demande d'achat")]
StatusFilter = Annotated[
    PurchaseStatus | None, Query(alias="status", description="Filtrer sur un état")
]

_STATE_ERROR = (
    "`409 PURCHASE_STATE` (`meta.status` : état actuel, `meta.expected` : états acceptés)"
)


# --- Budget Marché -----------------------------------------------------------------------


@router.get(
    "/market/budget-status",
    response_model=MarketBudgetStatusOut,
    summary="Consulter le statut du budget marché (jauge)",
)
def get_purchase_market_budget_status(
    user: CurrentUser,
    db: DbSession,
    total_budget_xof: Annotated[int, Query(ge=0, description="Montant total en FCFA estimé")] = 0,
) -> MarketBudgetStatusOut:
    """Retourne l'état de remplissage de la jauge budgétaire marché.
    Pour l'économe/acheteur, aucun montant en FCFA n'est retourné (confidentialité)."""
    return purchase_service.market_budget_status(db, user, total_budget_xof)


# --- Acheteur ----------------------------------------------------------------------------


@router.get("/articles", response_model=Page[PurchaseArticleOut], summary="Articles à acheter")
def articles(
    _: Acheteur,
    db: DbSession,
    category: Annotated[StockArticleCategory | None, Query(description="Une famille")] = None,
    search: Annotated[str | None, Query(max_length=60, description="Nom (contient)")] = None,
) -> Page[PurchaseArticleOut]:
    """Articles actifs, par famille puis par nom, **sans prix** : stock actuel et alerte
    seulement. Rôle : ACHETEUR et au-dessus."""
    return Page(items=purchase_service.articles(db, category=category, search=search))


@router.post(
    "",
    response_model=BuyerPurchaseOut,
    status_code=status.HTTP_201_CREATED,
    summary="Envoyer une demande d'achat",
)
def create(
    body: PurchaseCreate,
    user: Acheteur,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> BuyerPurchaseOut:
    """Quantités à acheter ; la réponse donne `amount_xof`, le montant qui sera remis
    (dernier prix d'achat de chaque article, à défaut son coût moyen), sans détail des prix.
    La demande apparaît aussitôt chez le responsable et l'admin (`GET /purchases`,
    `GET /purchases/pending-count`).

    Idempotent (`Idempotency-Key` obligatoire) : un rejeu renvoie la demande d'origine en `200`
    avec `Idempotent-Replay: true`.

    Erreurs : `404 NOT_FOUND` (`meta.article_ids` : articles inconnus ou désactivés),
    `409 IDEMPOTENCY_CONFLICT`, `422 VALIDATION_ERROR` (article présent deux fois,
    quantité ≤ 0).
    """
    result, replayed = purchase_service.create(
        db, body, key=idempotency_key, path=request.url.path, user=user, ctx=ctx
    )
    if replayed:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replay"] = "true"
    return result


@router.get("/mine", response_model=Page[BuyerPurchaseSummaryOut], summary="Mes demandes d'achat")
def mine(
    user: Acheteur, db: DbSession, page: Paging, status_filter: StatusFilter = None
) -> Page[BuyerPurchaseSummaryOut]:
    """Demandes de l'utilisateur connecté, les plus récentes en premier, paginées."""
    rows = purchases_repo.list_requests(db, status=status_filter, requested_by=user.id, page=page)
    items, next_cursor = split(rows, page, lambda r: (r.created_at, r.id))
    return Page(items=[purchase_service.buyer_summary(r) for r in items], next_cursor=next_cursor)


@router.get("/mine/{purchase_id}", response_model=BuyerPurchaseOut, summary="Ma demande")
def my_request(purchase_id: PurchaseId, user: Acheteur, db: DbSession) -> BuyerPurchaseOut:
    """Quantités demandées, validées et reçues, montant à remettre ; jamais de prix.
    Erreurs : `404 NOT_FOUND` (inconnue, ou demande d'un autre utilisateur)."""
    request = purchase_service.get_own_request(db, purchase_id, user)
    return purchase_service.buyer_out(db, request)


@router.post(
    "/mine/{purchase_id}/cancel", response_model=BuyerPurchaseOut, summary="Retirer ma demande"
)
def cancel(
    purchase_id: PurchaseId, body: PurchaseCancel, user: Acheteur, db: DbSession, ctx: Ctx
) -> BuyerPurchaseOut:
    request = purchase_service.cancel(db, purchase_id, reason=body.reason, user=user, ctx=ctx)
    return purchase_service.buyer_out(db, request)


cancel.__doc__ = f"""Tant qu'elle n'est pas validée (`SUBMITTED` → `CANCELLED`).
Erreurs : `404 NOT_FOUND`, {_STATE_ERROR}."""


# --- Responsable -------------------------------------------------------------------------


@router.get("", response_model=Page[PurchaseSummaryOut], summary="Demandes d'achat (suivi)")
def list_requests(
    _: Responsable, db: DbSession, page: Paging, status_filter: StatusFilter = None
) -> Page[PurchaseSummaryOut]:
    """Toutes les demandes, les plus récentes en premier, paginées, avec tous les montants.
    Réservé au RESPONSABLE."""
    rows = purchases_repo.list_requests(db, status=status_filter, requested_by=None, page=page)
    items, next_cursor = split(rows, page, lambda r: (r.created_at, r.id))
    return Page(items=purchase_service.summaries(db, items), next_cursor=next_cursor)


@router.get(
    "/pending-count", response_model=PurchasePendingOut, summary="Demandes en attente d'action"
)
def pending_count(_: Responsable, db: DbSession) -> PurchasePendingOut:
    """Compteurs pour un badge : à valider, à décaisser, à réceptionner."""
    return purchase_service.pending(db)


@router.get("/{purchase_id}", response_model=PurchaseOut, summary="Détail d'une demande")
def get_request(purchase_id: PurchaseId, _: Responsable, db: DbSession) -> PurchaseOut:
    """Lignes avec prix d'une unité, montant par ligne et montants reçus.
    Erreurs : `404 NOT_FOUND`."""
    return purchase_service.to_out(db, purchase_service.get_request(db, purchase_id))


@router.post("/{purchase_id}/approve", response_model=PurchaseOut, summary="Valider")
def approve(
    purchase_id: PurchaseId, body: PurchaseApprove, user: Responsable, db: DbSession, ctx: Ctx
) -> PurchaseOut:
    request = purchase_service.approve(db, purchase_id, body, user=user, ctx=ctx)
    return purchase_service.to_out(db, request)


approve.__doc__ = f"""`SUBMITTED` → `APPROVED`. Corrections facultatives par ligne : quantité
(0 : ligne retirée) et prix d'une unité ; `approved_total_xof` est recalculé, et c'est le montant
que voit l'acheteur.

Erreurs : `404 NOT_FOUND` (`meta.line_ids`), {_STATE_ERROR}, `422 VALIDATION_ERROR` (toutes
les quantités à 0 : refuser plutôt)."""


@router.post("/{purchase_id}/reject", response_model=PurchaseOut, summary="Refuser")
def reject(
    purchase_id: PurchaseId, body: PurchaseReject, user: Responsable, db: DbSession, ctx: Ctx
) -> PurchaseOut:
    request = purchase_service.reject(db, purchase_id, reason=body.reason, user=user, ctx=ctx)
    return purchase_service.to_out(db, request)


reject.__doc__ = f"""`SUBMITTED` ou `APPROVED` → `REJECTED`, avec un motif visible par
l'acheteur. Erreurs : `404 NOT_FOUND`, {_STATE_ERROR}."""


@router.post("/{purchase_id}/disburse", response_model=PurchaseOut, summary="Décaisser")
def disburse(
    purchase_id: PurchaseId, body: PurchaseDisburse, user: Responsable, db: DbSession, ctx: Ctx
) -> PurchaseOut:
    request = purchase_service.disburse(
        db, purchase_id, amount_xof=body.amount_xof, user=user, ctx=ctx
    )
    return purchase_service.to_out(db, request)


disburse.__doc__ = f"""`APPROVED` → `DISBURSED` : argent remis à l'acheteur (enregistrement
seulement, pas de mouvement de tiroir). `amount_xof` : défaut le total validé.

Erreurs : `404 NOT_FOUND`, {_STATE_ERROR}, `422 VALIDATION_ERROR` (total validé nul et
`amount_xof` absent)."""


@router.post("/{purchase_id}/receive", response_model=PurchaseOut, summary="Réceptionner")
def receive(
    purchase_id: PurchaseId, body: PurchaseReceive, user: Responsable, db: DbSession, ctx: Ctx
) -> PurchaseOut:
    request = purchase_service.receive(db, purchase_id, body, user=user, ctx=ctx)
    return purchase_service.to_out(db, request)


receive.__doc__ = f"""`DISBURSED` → `RECEIVED`. Par ligne : quantité achetée et montant payé ;
une entrée de stock (`PURCHASE_IN`) est créée au prix payé, le coût moyen est recalculé. Une
ligne validée absente compte comme non trouvée (0). `change_due_xof` = remis - dépensé
(négatif : la caisse doit à l'acheteur).

Erreurs : `404 NOT_FOUND` (`meta.line_ids`), {_STATE_ERROR}, `422 VALIDATION_ERROR` (ligne en
double, ligne retirée à la validation, montant pour une quantité nulle)."""
