import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Path, Query, status
from sqlalchemy.orm import Session

from caisse.deps import Ctx, CurrentUser, DbSession, OverrideTokenHeader, Paging
from caisse.domain.enums import OrderStatus, UserRole, role_at_least
from caisse.errors import InsufficientPrivilegeError
from caisse.pagination import split
from caisse.repositories import orders as orders_repo
from caisse.schemas.common import Page
from caisse.schemas.orders import (
    CancelOrder,
    ItemAdd,
    ItemUpdate,
    OrderCreate,
    OrderOut,
    OrderResult,
    OrderSummaryOut,
)
from caisse.security import utcnow
from caisse.services import auth_service, order_service

router = APIRouter(prefix="/orders", tags=["Commandes"])

OrderId = Annotated[uuid.UUID, Path(description="Identifiant de la commande")]
ItemId = Annotated[uuid.UUID, Path(description="Identifiant de la ligne")]


def _result(db: Session, order_id: uuid.UUID) -> OrderResult:
    return OrderResult(order=order_service.to_out(db, order_service.get_order(db, order_id)))


@router.post(
    "",
    response_model=OrderResult,
    status_code=status.HTTP_201_CREATED,
    summary="Créer une commande",
)
def create_order(body: OrderCreate, user: CurrentUser, db: DbSession, ctx: Ctx) -> OrderResult:
    """Sur une table (`table_id`) ou à emporter (`table_id: null` → `counter_number` attribué).
    La commande est rattachée à la session de caisse ouverte.

    Partage de table : une table occupée refuse une nouvelle commande, sauf avec
    `allow_multiple: true` ou une `note_label`. Chaque commande d'une table porte une
    étiquette (`note_label`, défaut « Note 1 », « Note 2 »… premier numéro libre).

    Erreurs : `409 NO_OPEN_SESSION`, `404 NOT_FOUND` (table inconnue ou désactivée),
    `409 TABLE_ALREADY_OCCUPIED` (`meta.order_id` : la plus ancienne commande active,
    `meta.active_orders`), `409 ORDER_LABEL_TAKEN` (étiquette déjà prise sur la table).
    """
    order = order_service.create_order(
        db,
        table_id=body.table_id,
        guests_count=body.guests_count,
        note_label=body.note_label,
        allow_multiple=body.allow_multiple,
        actor_id=user.id,
        ctx=ctx,
    )
    return _result(db, order.id)


@router.get("", response_model=Page[OrderSummaryOut], summary="Lister les commandes")
def list_orders(
    user: CurrentUser,
    db: DbSession,
    page: Paging,
    business_date: Annotated[
        date | None,
        Query(
            description="Journée comptable ; défaut : celle de la session ouverte, sinon le jour"
        ),
    ] = None,
    status_filter: Annotated[
        OrderStatus | None, Query(alias="status", description="Filtrer sur un statut")
    ] = None,
) -> Page[OrderSummaryOut]:
    """Commandes d'une journée, les plus récentes en premier (sans les lignes : voir
    `GET /orders/{id}`), par pages de `limit` : `next_cursor` donne la suivante. Le CAISSIER
    ne voit que la journée de la session ouverte ; les autres journées sont réservées au
    RESPONSABLE.

    Erreurs : `403 INSUFFICIENT_PRIVILEGE`.
    """
    session = auth_service.current_open_session(db)
    current_date = session.business_date if session else None
    effective_date = business_date or current_date or utcnow().date()
    if effective_date != current_date and not role_at_least(user.role, UserRole.RESPONSABLE):
        raise InsufficientPrivilegeError(meta={"required_role": UserRole.RESPONSABLE})
    rows = orders_repo.list_orders(
        db, business_date=effective_date, status=status_filter, page=page
    )
    orders, next_cursor = split(rows, page, lambda o: (o.opened_at, o.id))
    return Page(items=[order_service.to_summary(o) for o in orders], next_cursor=next_cursor)


@router.get("/{order_id}", response_model=OrderOut, summary="Détail d'une commande")
def get_order(order_id: OrderId, _: CurrentUser, db: DbSession) -> OrderOut:
    """Commande complète avec ses lignes actives. Erreurs : `404 NOT_FOUND`."""
    return order_service.to_out(db, order_service.get_order(db, order_id))


@router.post(
    "/{order_id}/items",
    response_model=OrderResult,
    status_code=status.HTTP_201_CREATED,
    summary="Ajouter une ligne",
)
def add_item(order_id: OrderId, body: ItemAdd, user: CurrentUser, db: DbSession) -> OrderResult:
    """Le prix et le libellé du produit sont **figés** sur la ligne. Renvoie la commande
    complète, totaux recalculés.

    Erreurs : `404 NOT_FOUND` (commande ou produit), `409 ORDER_NOT_EDITABLE`,
    `422 VALIDATION_ERROR` (produit désactivé : `meta.fields[0].type = "product_inactive"`).
    """
    order_service.add_item(
        db,
        order_id,
        product_id=body.product_id,
        quantity=body.quantity,
        note=body.note,
        actor_id=user.id,
    )
    return _result(db, order_id)


@router.patch(
    "/{order_id}/items/{item_id}", response_model=OrderResult, summary="Modifier une ligne"
)
def update_item(
    order_id: OrderId, item_id: ItemId, body: ItemUpdate, user: CurrentUser, db: DbSession, ctx: Ctx
) -> OrderResult:
    """Quantité et/ou note ; seuls les champs envoyés changent. Tracé dans l'audit.

    Erreurs : `404 NOT_FOUND`, `409 ORDER_NOT_EDITABLE`.
    """
    order_service.update_item(
        db,
        order_id,
        item_id,
        changes=body.model_dump(exclude_unset=True),
        actor_id=user.id,
        ctx=ctx,
    )
    return _result(db, order_id)


@router.delete(
    "/{order_id}/items/{item_id}", response_model=OrderResult, summary="Retirer une ligne"
)
def remove_item(
    order_id: OrderId,
    item_id: ItemId,
    reason: Annotated[str, Query(min_length=1, max_length=255, description="Motif du retrait")],
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
) -> OrderResult:
    """La ligne n'est jamais supprimée : elle est marquée retirée (qui, quand, motif) et
    comptée dans le rapport Z. Aucune autorisation de responsable n'est demandée.

    Erreurs : `404 NOT_FOUND`, `409 ORDER_NOT_EDITABLE`.
    """
    order_service.remove_item(db, order_id, item_id, reason=reason, actor_id=user.id, ctx=ctx)
    return _result(db, order_id)


@router.post("/{order_id}/cancel", response_model=OrderResult, summary="Annuler une commande")
def cancel_order(
    order_id: OrderId,
    body: CancelOrder,
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    override_token: OverrideTokenHeader = None,
) -> OrderResult:
    """Libère la table. RESPONSABLE : direct. CAISSIER : `X-Override-Token` obtenu avec
    l'action `order.cancel`.

    Erreurs : `404 NOT_FOUND`, `409 ORDER_NOT_EDITABLE` (déjà soldée/annulée, ou paiements
    déjà enregistrés : `meta.reason = "has_payments"`), `403 OVERRIDE_REQUIRED`.
    """
    order_service.cancel_order(
        db, order_id, reason=body.reason, user=user, override_token=override_token, ctx=ctx
    )
    return _result(db, order_id)


@router.post("/{order_id}/reprint", response_model=OrderResult, summary="Ré-imprimer le ticket")
def reprint(order_id: OrderId, user: CurrentUser, db: DbSession, ctx: Ctx) -> OrderResult:
    """Ré-imprime le dernier ticket tel que remis au client (tracé, compté dans les contrôles
    X/Z). N'ouvre pas le tiroir.

    Erreurs : `404 NOT_FOUND`, `409 NO_RECEIPT_TO_REPRINT` (aucun ticket encore imprimé).
    """
    order_out = order_service.reprint(db, order_id, user_id=user.id, ctx=ctx)
    return OrderResult(order=order_out)
