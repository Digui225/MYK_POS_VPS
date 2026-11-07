from datetime import date

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse.core import idempotency
from caisse.core.database import get_db
from caisse.core.deps import Paging, require_device_id, require_role
from caisse.core.idempotency import IdempotencyKey, OptionalIdempotencyKey
from caisse.domain.enums import UserRole
from caisse.models.user import User
from caisse.schemas.common import Page
from caisse.schemas.orders import (
    OrderCancelRequest,
    OrderCreateRequest,
    OrderDispatchRequest,
    OrderDispatchResponse,
    OrderItemAddRequest,
    OrderItemRemoveRequest,
    OrderResponse,
    OrderSplitResponse,
)
from caisse.services.order_service import OrderService

router = APIRouter(prefix="/orders", tags=["Commandes"])


@router.post("", response_model=OrderResponse, status_code=status.HTTP_201_CREATED, summary="Créer une commande")
async def create_order(
    payload: OrderCreateRequest,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    current_user: User = Depends(require_role("CAISSIER", "SERVEUR")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderResponse:
    """Avec `Idempotency-Key` (téléphone de salle), une création rejouée après une coupure
    du Wi-Fi renvoie la note déjà ouverte au lieu d'en ouvrir une seconde."""
    request_hash = idempotency.hash_request(payload)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return OrderResponse.model_validate(replay)

    service = OrderService(db)
    # Une note ouverte par un serveur est à son nom (écran salle) ; à la caisse, sans serveur
    served_by = current_user.id if current_user.role == UserRole.SERVEUR else None
    result = service.create_order(
        payload, user_id=current_user.id, device_id=device_id, served_by_user_id=served_by
    )

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=201,
            body=result.model_dump(mode="json"),
            user_id=current_user.id,
        )
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            replay = idempotency.find_replay(
                db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
            )
            if replay is not None:
                idempotency.apply_replay_headers(response)
                return OrderResponse.model_validate(replay)
            raise

    return result


@router.get("", response_model=Page[OrderResponse], summary="Lister les commandes")
async def list_orders(
    page: Paging,
    current_user: User = Depends(require_role("CAISSIER", "SERVEUR", "RESPONSABLE", "ADMIN")),
    session_id: str | None = None,
    status: str | None = None,
    business_date: date | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    order_type: str | None = None,
    search: str | None = None,
    db: Session = Depends(get_db),
) -> Page[OrderResponse]:
    service = OrderService(db)
    items, next_cursor = service.list_orders(
        page=page,
        session_id=session_id,
        status=status,
        business_date=business_date,
        date_from=date_from,
        date_to=date_to,
        order_type=order_type,
        search=search,
    )
    return Page(items=items, next_cursor=next_cursor)


@router.get("/{id}", response_model=OrderResponse, summary="Détail d'une commande")
async def get_order(
    id: str,
    current_user: User = Depends(require_role("CAISSIER", "SERVEUR")),
    db: Session = Depends(get_db),
) -> OrderResponse:
    service = OrderService(db)
    return service.get_order(id)


@router.post("/{id}/items", response_model=OrderResponse, summary="Ajouter une ligne de commande")
async def add_order_item(
    id: str,
    payload: OrderItemAddRequest,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    current_user: User = Depends(require_role("CAISSIER")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderResponse:
    request_hash = idempotency.hash_request(payload)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return OrderResponse.model_validate(replay)

    service = OrderService(db)
    result = service.add_item(id, payload, user_id=current_user.id, device_id=device_id)

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=200,
            body=result.model_dump(mode="json"),
            user_id=current_user.id,
        )
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            replay = idempotency.find_replay(
                db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
            )
            if replay is not None:
                idempotency.apply_replay_headers(response)
                return OrderResponse.model_validate(replay)
            raise

    return result


@router.post(
    "/{id}/dispatch",
    response_model=OrderDispatchResponse,
    summary="Envoyer en cuisine (lignes + bon cuisine, idempotent)",
)
async def dispatch_order(
    id: str,
    payload: OrderDispatchRequest,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
    current_user: User = Depends(require_role("CAISSIER", "SERVEUR")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderDispatchResponse:
    """Enregistre toutes les lignes d'un envoi et met en file, à la caisse, le bon cuisine
    (boissons exclues). Lignes, bon et clé d'idempotence sont validés ensemble : un envoi
    interrompu n'enregistre rien, un envoi rejoué renvoie la première réponse sans rien doubler."""
    request_hash = idempotency.hash_request(payload)
    replay = idempotency.find_replay(
        db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
    )
    if replay is not None:
        idempotency.apply_replay_headers(response)
        return OrderDispatchResponse.model_validate(replay)

    service = OrderService(db)
    try:
        order, result = service.dispatch(id, payload, user=current_user, device_id=device_id)
    except Exception:
        db.rollback()  # une ligne refusée : aucune ligne de l'envoi n'est gardée
        raise
    idempotency.save(
        db,
        idempotency_key,
        method="POST",
        path=request.url.path,
        request_hash=request_hash,
        status=200,
        body=result.model_dump(mode="json"),
        user_id=current_user.id,
    )
    try:
        db.commit()
    except IntegrityError:
        # Même clé validée entre-temps par une autre requête : rien n'est doublé
        db.rollback()
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return OrderDispatchResponse.model_validate(replay)
        raise

    service.broadcast_order_updated(order, dispatch_no=result.dispatch_no)
    return result


@router.post(
    "/{id}/split-by-seat",
    response_model=OrderSplitResponse,
    summary="Séparer l'addition par convive (une note par convive, avant tout paiement)",
)
async def split_order_by_seat(
    id: str,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
    current_user: User = Depends(require_role("SERVEUR", "CAISSIER")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderSplitResponse:
    """Deux clients qui ne sont pas ensemble paient séparément : chaque autre convive part sur
    sa propre note (son ticket, sa FNE). Tout ou rien ; une séparation rejouée (même clé)
    renvoie le premier résultat sans rien refaire."""
    request_hash = idempotency.hash_request(None)
    replay = idempotency.find_replay(
        db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
    )
    if replay is not None:
        idempotency.apply_replay_headers(response)
        return OrderSplitResponse.model_validate(replay)

    service = OrderService(db)
    try:
        orders = service.split_by_seat(id, user=current_user, device_id=device_id)
        result = OrderSplitResponse(orders=[service._to_order_response(o) for o in orders])
    except Exception:
        db.rollback()
        raise
    idempotency.save(
        db,
        idempotency_key,
        method="POST",
        path=request.url.path,
        request_hash=request_hash,
        status=200,
        body=result.model_dump(mode="json"),
        user_id=current_user.id,
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return OrderSplitResponse.model_validate(replay)
        raise
    for o in orders:
        service.broadcast_order_updated(o, split=True)
    return result


@router.post(
    "/{id}/bill-request",
    response_model=OrderResponse,
    summary="Demander l'addition à la caisse (serveur)",
)
async def request_bill(
    id: str,
    current_user: User = Depends(require_role("SERVEUR", "CAISSIER")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderResponse:
    return OrderService(db).request_bill(id, user_id=current_user.id, device_id=device_id)


@router.delete("/{id}/items/{item_id}", response_model=OrderResponse, summary="Retirer une ligne (tracé)")
async def remove_order_item(
    id: str,
    item_id: str,
    payload: OrderItemRemoveRequest,
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderResponse:
    service = OrderService(db)
    return service.remove_item(id, item_id, payload, user_id=current_user.id, device_id=device_id)


@router.post("/{id}/cancel", response_model=OrderResponse, summary="Annuler une commande (tracé)")
async def cancel_order(
    id: str,
    payload: OrderCancelRequest,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OrderResponse:
    request_hash = idempotency.hash_request(payload)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return OrderResponse.model_validate(replay)

    service = OrderService(db)
    result = service.cancel_order(id, payload, user_id=current_user.id, device_id=device_id)

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=200,
            body=result.model_dump(mode="json"),
            user_id=current_user.id,
        )
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            replay = idempotency.find_replay(
                db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
            )
            if replay is not None:
                idempotency.apply_replay_headers(response)
                return OrderResponse.model_validate(replay)
            raise

    return result
