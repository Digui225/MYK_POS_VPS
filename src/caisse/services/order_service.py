import uuid

from sqlalchemy.orm import Session

from caisse.domain.enums import (
    ACTIVE_ORDER_STATUSES,
    OrderStatus,
    PrintJobType,
    UserRole,
    role_at_least,
)
from caisse.domain.money import line_total, split_vat_by_rate
from caisse.errors import (
    NoOpenSessionError,
    NoReceiptToReprintError,
    NotFoundError,
    OrderLabelTakenError,
    OrderNotEditableError,
    TableAlreadyOccupiedError,
    ValidationError,
)
from caisse.models.catalog import Category, Product
from caisse.models.order import Order, OrderItem
from caisse.models.user import User
from caisse.repositories import orders as orders_repo
from caisse.repositories import payments as payments_repo
from caisse.repositories import print_jobs as print_jobs_repo
from caisse.repositories import tables as tables_repo
from caisse.schemas.orders import OrderItemOut, OrderOut, OrderSummaryOut
from caisse.schemas.payments import PaymentOut
from caisse.security import utcnow
from caisse.sequences import next_value
from caisse.services import audit_service, auth_service, printing_service
from caisse.services.audit_service import RequestContext

CANCEL_ACTION = "order.cancel"


def to_summary(order: Order) -> OrderSummaryOut:
    return OrderSummaryOut.model_validate(order)


def to_out(db: Session, order: Order) -> OrderOut:
    items = [
        OrderItemOut(
            id=item.id,
            product_id=item.product_id,
            name=item.product_name_snapshot,
            unit_price_xof=item.unit_price_xof,
            quantity=item.quantity,
            line_total_xof=item.line_total_xof,
            note=item.note,
            added_at=item.added_at,
        )
        for item in orders_repo.active_items(db, order.id)
    ]
    payments = [PaymentOut.model_validate(p) for p in payments_repo.for_order(db, order.id)]
    return OrderOut(**to_summary(order).model_dump(), items=items, payments=payments)


def get_order(db: Session, order_id: uuid.UUID) -> Order:
    order = orders_repo.get(db, order_id)
    if order is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    return order


def _editable_order(db: Session, order_id: uuid.UUID) -> Order:
    order = orders_repo.get_for_update(db, order_id)
    if order is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    if order.status not in ACTIVE_ORDER_STATUSES:
        raise OrderNotEditableError(meta={"order_id": str(order.id), "status": order.status})
    return order


def _recompute(db: Session, order: Order) -> None:
    """Le TTC des lignes fait foi ; HT et TVA en sont déduits par taux (00-ARCHITECTURE §7.1)."""
    db.flush()
    items = orders_repo.active_items(db, order.id)
    breakdown = split_vat_by_rate([(item.line_total_xof, item.vat_rate) for item in items])
    if breakdown.ttc_xof < order.paid_xof:
        raise OrderNotEditableError(
            meta={
                "order_id": str(order.id),
                "reason": "total_below_paid",
                "paid_xof": order.paid_xof,
            }
        )
    order.total_ttc_xof = breakdown.ttc_xof
    order.total_ht_xof = breakdown.ht_xof
    order.total_vat_xof = breakdown.vat_xof
    order.due_xof = breakdown.ttc_xof - order.paid_xof


def authorize_manager(
    db: Session, user: User, override_token: str | None, action: str
) -> uuid.UUID | None:
    """Responsable : direct. Caissier : jeton d'override consommé. Retourne l'id de l'autorisant."""
    if role_at_least(user.role, UserRole.RESPONSABLE):
        return None
    granter = auth_service.consume_override(
        db, override_token, requested_by=user, action=action, required_role=UserRole.RESPONSABLE
    )
    return granter.id


def _table_label(
    db: Session, table_id: uuid.UUID, note_label: str | None, allow_multiple: bool
) -> str:
    """Étiquette de la nouvelle commande d'une table. La table est verrouillée : deux postes
    qui ouvrent la même table se sérialisent, le second voit la commande du premier."""
    table = tables_repo.get_for_update(db, table_id)
    if table is None or not table.is_active:
        raise NotFoundError(meta={"table_id": str(table_id)})
    active = orders_repo.active_for_table(db, table_id)
    if active and not (allow_multiple or note_label):
        raise TableAlreadyOccupiedError(
            meta={"order_id": str(active[0].id), "active_orders": len(active)}
        )
    used = {(o.note_label or "").lower(): o for o in active}
    if note_label is not None:
        taken = used.get(note_label.lower())
        if taken is not None:
            raise OrderLabelTakenError(meta={"order_id": str(taken.id), "note_label": note_label})
        return note_label
    number = 1
    while f"note {number}" in used:
        number += 1
    return f"Note {number}"


def create_order(
    db: Session,
    *,
    table_id: uuid.UUID | None,
    guests_count: int | None,
    note_label: str | None = None,
    allow_multiple: bool = False,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> Order:
    """Sur une table libre : « Note 1 ». Sur une table occupée : refus, sauf partage demandé
    (`allow_multiple` ou étiquette fournie) ; la nouvelle commande prend le premier numéro
    « Note n » libre. À emporter : numéro de comptoir, étiquette facultative."""
    session = auth_service.current_open_session(db)
    if session is None:
        raise NoOpenSessionError()

    if table_id is not None:
        note_label = _table_label(db, table_id, note_label, allow_multiple)

    business_date = session.business_date
    number = next_value(db, f"order:{business_date.isoformat()}")
    counter_number = (
        next_value(db, f"counter:{business_date.isoformat()}") if table_id is None else None
    )
    order = Order(
        order_number=f"{business_date.isoformat()}-{number:04d}",
        business_date=business_date,
        counter_number=counter_number,
        cash_session_id=session.id,
        table_id=table_id,
        status=OrderStatus.OPEN,
        opened_by_user_id=actor_id,
        guests_count=guests_count,
        note_label=note_label,
        opened_at=utcnow(),
    )
    db.add(order)
    db.flush()
    audit_service.log(
        db,
        "order.create",
        ctx=ctx,
        user_id=actor_id,
        entity="order",
        entity_id=order.id,
        after={
            "order_number": order.order_number,
            "table_id": str(table_id) if table_id else None,
            "note_label": note_label,
        },
    )
    db.commit()
    return order


def add_item(
    db: Session,
    order_id: uuid.UUID,
    *,
    product_id: uuid.UUID,
    quantity: int,
    note: str | None,
    actor_id: uuid.UUID,
) -> Order:
    order = _editable_order(db, order_id)
    product = db.get(Product, product_id)
    if product is None:
        raise NotFoundError(meta={"product_id": str(product_id)})
    if not product.is_active:
        raise ValidationError(
            "Produit désactivé",
            meta={"fields": [{"loc": ["body", "product_id"], "type": "product_inactive"}]},
        )
    category = db.get(Category, product.category_id)
    assert category is not None
    db.add(
        OrderItem(
            order_id=order.id,
            product_id=product.id,
            product_name_snapshot=product.name,
            category_snapshot=category.name,
            fiscal_group_snapshot=category.fiscal_group,
            unit_price_xof=product.price_xof,
            quantity=quantity,
            vat_rate=product.vat_rate,
            line_total_xof=line_total(product.price_xof, quantity),
            note=note,
            added_by_user_id=actor_id,
            added_at=utcnow(),
        )
    )
    _recompute(db, order)
    db.commit()
    return order


def update_item(
    db: Session,
    order_id: uuid.UUID,
    item_id: uuid.UUID,
    *,
    changes: dict[str, object],
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> Order:
    """`changes` ne contient que les champs réellement envoyés (`quantity`, `note`)."""
    order = _editable_order(db, order_id)
    item = orders_repo.get_active_item(db, order.id, item_id)
    if item is None:
        raise NotFoundError(meta={"item_id": str(item_id)})
    before = {"quantity": item.quantity, "note": item.note}
    quantity = changes.get("quantity")
    if isinstance(quantity, int):
        item.quantity = quantity
        item.line_total_xof = line_total(item.unit_price_xof, quantity)
    if "note" in changes:
        note = changes["note"]
        item.note = note if isinstance(note, str) else None
    _recompute(db, order)
    audit_service.log(
        db,
        "order.item_update",
        ctx=ctx,
        user_id=actor_id,
        entity="order_item",
        entity_id=item.id,
        before=before,
        after={"quantity": item.quantity, "note": item.note},
    )
    db.commit()
    return order


def remove_item(
    db: Session,
    order_id: uuid.UUID,
    item_id: uuid.UUID,
    *,
    reason: str,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> Order:
    order = _editable_order(db, order_id)
    item = orders_repo.get_active_item(db, order.id, item_id)
    if item is None:
        raise NotFoundError(meta={"item_id": str(item_id)})
    item.removed_at = utcnow()
    item.removed_by_user_id = actor_id
    item.removal_reason = reason
    _recompute(db, order)
    audit_service.log(
        db,
        "order.item_remove",
        ctx=ctx,
        user_id=actor_id,
        entity="order_item",
        entity_id=item.id,
        before={
            "product": item.product_name_snapshot,
            "quantity": item.quantity,
            "line_total_xof": item.line_total_xof,
        },
        reason=reason,
    )
    db.commit()
    return order


def cancel_order(
    db: Session,
    order_id: uuid.UUID,
    *,
    reason: str,
    user: User,
    override_token: str | None,
    ctx: RequestContext,
) -> Order:
    order = _editable_order(db, order_id)
    if order.paid_xof > 0:
        # annuler d'abord les paiements (DELETE /orders/{id}/payments/{payment_id})
        raise OrderNotEditableError(
            meta={"order_id": str(order.id), "reason": "has_payments", "paid_xof": order.paid_xof}
        )
    granted_by = authorize_manager(db, user, override_token, CANCEL_ACTION)
    before_status = order.status
    order.status = OrderStatus.CANCELLED
    order.cancelled_reason = reason
    order.cancelled_by = user.id
    order.cancelled_at = utcnow()
    order.closed_by_user_id = user.id
    order.due_xof = 0
    audit_service.log(
        db,
        "order.cancel",
        ctx=ctx,
        user_id=user.id,
        acting_as_user_id=granted_by,
        entity="order",
        entity_id=order.id,
        before={"status": before_status, "total_ttc_xof": order.total_ttc_xof},
        after={"status": order.status},
        reason=reason,
    )
    db.commit()
    return order


def reprint(
    db: Session, order_id: uuid.UUID, *, user_id: uuid.UUID, ctx: RequestContext
) -> OrderOut:
    """Ré-imprime le dernier ticket **tel que remis au client** (le contenu stocké, jamais
    ré-rendu depuis l'état courant : un retrait ou un avoir ultérieur ne doit pas changer
    rétroactivement ce que montre une ré-impression)."""
    order = get_order(db, order_id)
    previous = print_jobs_repo.latest_receipt_for_order(db, order.id)
    if previous is None or not previous.rendered:
        raise NoReceiptToReprintError(meta={"order_id": str(order_id)})
    job = printing_service.enqueue(
        db,
        job_type=PrintJobType.RECEIPT,
        rendered=previous.rendered,
        open_drawer=False,
        order_id=order.id,
        payload=previous.payload,
        is_reprint=True,
        user_id=user_id,
    )
    audit_service.log(
        db, "order.reprint", ctx=ctx, user_id=user_id, entity="print_job", entity_id=job.id
    )
    db.commit()
    return to_out(db, order)
