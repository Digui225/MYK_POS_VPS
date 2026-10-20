import uuid
from typing import Annotated

from fastapi import APIRouter, Path, Query, Request, Response, status

from caisse.deps import Ctx, CurrentUser, DbSession, OverrideTokenHeader
from caisse.idempotency import IdempotencyKey
from caisse.schemas.orders import OrderResult, PaymentResult
from caisse.schemas.payments import PaymentCreate, PaymentMethodOut
from caisse.services import order_service, payment_service

router = APIRouter(tags=["Paiements"])

OrderId = Annotated[uuid.UUID, Path(description="Identifiant de la commande")]
PaymentId = Annotated[uuid.UUID, Path(description="Identifiant du paiement")]


@router.get("/payment-methods", response_model=list[PaymentMethodOut], summary="Moyens de paiement")
def payment_methods(_: CurrentUser, db: DbSession) -> list[PaymentMethodOut]:
    """Moyens proposés par la caisse (paramètre `payments.methods`), dans l'ordre d'affichage."""
    return payment_service.list_methods(db)


@router.post(
    "/orders/{order_id}/payments",
    response_model=PaymentResult,
    status_code=status.HTTP_201_CREATED,
    summary="Encaisser un paiement",
)
def register_payment(
    order_id: OrderId,
    body: PaymentCreate,
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> PaymentResult:
    """Idempotent (`Idempotency-Key` obligatoire) : un rejeu renvoie la réponse d'origine en
    `200` avec `Idempotent-Replay: true`, sans second paiement.

    Paiement partiel ou mixte : appeler autant de fois que nécessaire ; la commande passe
    `PARTIALLY_PAID`, puis `PAID` quand le reste dû tombe à 0 (la table est alors libérée).
    `amount_xof` ne dépasse jamais le reste dû ; en espèces, `tendered_xof` donne le rendu
    (`payment.change_xof`).

    Le paiement qui solde la commande déstocke les articles des fiches techniques ; warning
    `STOCK_NEGATIVE_WARNING` (`meta.article_id`) si un article passe sous zéro (non bloquant).

    Erreurs : `404 NOT_FOUND`, `409 ORDER_NOT_EDITABLE` (soldée, annulée, ou
    `meta.reason = "nothing_due"`), `422 PAYMENT_EXCEEDS_DUE` (`meta.due_xof`),
    `422 PAYMENT_METHOD_DISABLED`, `409 NO_OPEN_SESSION`, `409 IDEMPOTENCY_CONFLICT`,
    `422 VALIDATION_ERROR`.
    """
    result, replayed = payment_service.register_payment(
        db,
        order_id,
        body,
        idempotency_key=idempotency_key,
        path=request.url.path,
        user=user,
        ctx=ctx,
    )
    if replayed:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replay"] = "true"
    return result


@router.delete(
    "/orders/{order_id}/payments/{payment_id}",
    response_model=OrderResult,
    summary="Annuler un paiement",
)
def void_payment(
    order_id: OrderId,
    payment_id: PaymentId,
    reason: Annotated[
        str, Query(min_length=1, max_length=255, description="Motif de l'annulation")
    ],
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    override_token: OverrideTokenHeader = None,
) -> OrderResult:
    """Correction d'une erreur de saisie (mauvais moyen, mauvais montant) : le paiement est
    conservé avec `status: VOIDED` et la commande redevient `PARTIALLY_PAID` ou `OPEN`.
    RESPONSABLE : direct. CAISSIER : `X-Override-Token` obtenu avec l'action `payment.void`.

    Warning `FNE_ALREADY_ISSUED` si la commande a déjà une FNE : rien n'est fait
    automatiquement ; si la vente est réellement annulée, émettre un avoir.

    Erreurs : `404 NOT_FOUND`, `403 OVERRIDE_REQUIRED`, `409 PAYMENT_NOT_VOIDABLE`
    (`meta.reason` : `already_voided`, `session_closed` (session déjà clôturée),
    `order_status`). Une table rouverte entre-temps n'empêche plus l'annulation : la
    commande y redevient active à côté des autres (partage de table).
    """
    order, warnings = payment_service.void_payment(
        db,
        order_id,
        payment_id,
        reason=reason,
        user=user,
        override_token=override_token,
        ctx=ctx,
    )
    return OrderResult(order=order_service.to_out(db, order), warnings=warnings)
