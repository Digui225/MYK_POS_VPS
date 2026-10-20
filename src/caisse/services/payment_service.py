"""Encaissement (01-BACKEND §5.4) : verrou sur la commande, totaux recalculés depuis les paiements
capturés, idempotence par `Idempotency-Key` (enregistrement de la réponse + colonne UNIQUE)."""

import uuid
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.config import get_settings
from caisse.domain import receipt as receipt_domain
from caisse.domain.enums import (
    ACTIVE_ORDER_STATUSES,
    FneStatus,
    MobileMoneyProvider,
    OrderStatus,
    PaymentMethod,
    PaymentStatus,
    PrintJobType,
)
from caisse.domain.money import change_due, format_xof
from caisse.errors import (
    DomainError,
    IdempotencyConflictError,
    NoOpenSessionError,
    NotFoundError,
    OrderNotEditableError,
    PaymentExceedsDueError,
    PaymentMethodDisabledError,
    PaymentNotVoidableError,
)
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.models.table import RestaurantTable
from caisse.models.user import User
from caisse.repositories import fne as fne_repo
from caisse.repositories import orders as orders_repo
from caisse.repositories import payments as payments_repo
from caisse.repositories import settings as settings_repo
from caisse.schemas.common import ApiWarning
from caisse.schemas.orders import OrderOut, PaymentResult, ReceiptOut
from caisse.schemas.payments import PaymentCreate, PaymentMethodOut, PaymentOut
from caisse.security import utcnow
from caisse.services import (
    audit_service,
    auth_service,
    order_service,
    printing_service,
    stock_service,
)
from caisse.services.audit_service import RequestContext

VOID_ACTION = "payment.void"

DEFAULT_METHODS = [
    PaymentMethod.CASH,
    PaymentMethod.MOBILE_MONEY,
    PaymentMethod.CARD,
    PaymentMethod.BANK_TRANSFER,
    PaymentMethod.CREDIT,
]

_LABELS = {
    PaymentMethod.CASH: "Espèces",
    PaymentMethod.MOBILE_MONEY: "Mobile Money",
    PaymentMethod.CARD: "Carte bancaire",
    PaymentMethod.BANK_TRANSFER: "Virement",
    PaymentMethod.CREDIT: "Paiement différé",
    PaymentMethod.OTHER: "Autre",
}


def enabled_methods(db: Session) -> list[PaymentMethod]:
    """`payments.methods`, dans l'ordre du paramètre ; codes inconnus ignorés."""
    configured = settings_repo.get_value(db, "payments.methods", DEFAULT_METHODS)
    known = {m.value for m in PaymentMethod}
    return [PaymentMethod(code) for code in configured if code in known]


def list_methods(db: Session) -> list[PaymentMethodOut]:
    return [
        PaymentMethodOut(
            method=method,
            label=_LABELS[method],
            gives_change=method == PaymentMethod.CASH,
            providers=list(MobileMoneyProvider) if method == PaymentMethod.MOBILE_MONEY else [],
        )
        for method in enabled_methods(db)
    ]


def _apply_paid(db: Session, order: Order, user: User) -> list[ApiWarning]:
    """Payé et reste dû recalculés depuis les paiements capturés, jamais incrémentés.
    Le stock suit le statut : sortie quand la commande devient soldée, remise en stock quand
    un paiement annulé la fait sortir de `PAID` (même transaction). Retourne les
    avertissements de stock négatif."""
    db.flush()
    was_paid = order.status == OrderStatus.PAID
    order.paid_xof = payments_repo.captured_total(db, order.id)
    order.due_xof = order.total_ttc_xof - order.paid_xof
    if order.due_xof == 0:
        order.status = OrderStatus.PAID
        order.paid_at = order.paid_at or utcnow()
        order.closed_by_user_id = order.closed_by_user_id or user.id
    else:
        order.status = OrderStatus.PARTIALLY_PAID if order.paid_xof > 0 else OrderStatus.OPEN
        order.paid_at = None
        order.closed_by_user_id = None
    if order.status == OrderStatus.PAID and not was_paid:
        return stock_service.apply_sale(db, order, user.id)
    if was_paid and order.status != OrderStatus.PAID:
        stock_service.reverse_sale(db, order, user.id)
    return []


def _print_receipt(
    db: Session,
    order: Order,
    order_out: OrderOut,
    *,
    user_id: uuid.UUID,
    ctx: RequestContext,
) -> ReceiptOut:
    table_label = None
    if order.table_id is not None:
        table = db.get(RestaurantTable, order.table_id)
        table_label = table.label if table is not None else None
    header = settings_repo.get_value(db, "receipt.header", {})
    footer = settings_repo.get_value(db, "receipt.footer", "")
    rendered = receipt_domain.render_receipt(
        order_number=order_out.order_number,
        table_label=table_label,
        counter_number=order_out.counter_number,
        items=[
            receipt_domain.ReceiptLine(
                name=item.name,
                quantity=item.quantity,
                line_total_xof=item.line_total_xof,
                note=item.note,
            )
            for item in order_out.items
        ],
        payments=[
            receipt_domain.ReceiptPayment(
                method=payment.method,
                amount_xof=payment.amount_xof,
                change_xof=payment.change_xof,
                provider=payment.provider,
            )
            for payment in order_out.payments
            if payment.status != PaymentStatus.VOIDED
        ],
        total_ttc_xof=order_out.total_ttc_xof,
        header_name=str(header.get("name") or ""),
        header_address=header.get("address"),
        header_phone=header.get("phone"),
        header_ncc=header.get("ncc") or None,
        header_rccm=header.get("rccm") or None,
        footer=str(footer or ""),
        width=get_settings().printer_width,
    )
    job = printing_service.enqueue(
        db,
        job_type=PrintJobType.RECEIPT,
        rendered=rendered,
        open_drawer=True,
        order_id=order.id,
        user_id=user_id,
    )
    return ReceiptOut(print_job_id=job.id, status=job.status, drawer_opened=None)


def _replay(db: Session, key: str, path: str, request_hash: str) -> PaymentResult | None:
    body = idempotency.find_replay(db, key, method="POST", path=path, request_hash=request_hash)
    return None if body is None else PaymentResult.model_validate(body)


def register_payment(
    db: Session,
    order_id: uuid.UUID,
    body: PaymentCreate,
    *,
    idempotency_key: str,
    path: str,
    user: User,
    ctx: RequestContext,
) -> tuple[PaymentResult, bool]:
    """Retourne (résultat, rejoué). Un rejeu renvoie la réponse d'origine telle quelle."""
    request_hash = idempotency.hash_request(body)
    replay = _replay(db, idempotency_key, path, request_hash)
    if replay is not None:
        return replay, True

    order = orders_repo.get_for_update(db, order_id)
    if order is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    # le double envoi concurrent attendait le verrou : la première réponse est maintenant visible
    replay = _replay(db, idempotency_key, path, request_hash)
    if replay is not None:
        return replay, True

    if order.status not in ACTIVE_ORDER_STATUSES:
        raise OrderNotEditableError(meta={"order_id": str(order.id), "status": order.status})
    if order.due_xof <= 0:
        raise OrderNotEditableError(meta={"order_id": str(order.id), "reason": "nothing_due"})
    if body.method not in enabled_methods(db):
        raise PaymentMethodDisabledError(meta={"method": body.method})
    if body.amount_xof > order.due_xof:
        raise PaymentExceedsDueError(
            f"Reste dû : {format_xof(order.due_xof)} XOF, "
            f"montant proposé : {format_xof(body.amount_xof)} XOF.",
            meta={"due_xof": order.due_xof, "amount_xof": body.amount_xof},
        )
    session = auth_service.current_open_session(db)
    if session is None:
        raise NoOpenSessionError()

    payment = Payment(
        order_id=order.id,
        cash_session_id=session.id,
        method=body.method,
        provider=body.provider,
        amount_xof=body.amount_xof,
        tendered_xof=body.tendered_xof,
        change_xof=(
            change_due(body.amount_xof, body.tendered_xof) if body.tendered_xof is not None else 0
        ),
        reference=body.reference,
        status=PaymentStatus.CAPTURED,
        idempotency_key=idempotency_key,
        created_by_user_id=user.id,
    )
    db.add(payment)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        replay = _replay(db, idempotency_key, path, request_hash)
        if replay is not None:
            return replay, True
        raise IdempotencyConflictError(meta={"key": idempotency_key}) from None

    stock_warnings = _apply_paid(db, order, user)
    audit_service.log(
        db,
        "payment.create",
        ctx=ctx,
        user_id=user.id,
        entity="payment",
        entity_id=payment.id,
        after={
            "order_id": str(order.id),
            "method": body.method,
            "amount_xof": body.amount_xof,
            "order_status": order.status,
        },
    )
    order_out = order_service.to_out(db, order)
    receipt = (
        _print_receipt(db, order, order_out, user_id=user.id, ctx=ctx)
        if order.status == OrderStatus.PAID
        else None
    )
    result = PaymentResult(
        payment=PaymentOut.model_validate(payment),
        order=order_out,
        receipt=receipt,
        warnings=stock_warnings,
    )
    idempotency.save(
        db,
        idempotency_key,
        method="POST",
        path=path,
        request_hash=request_hash,
        status=201,
        body=result.model_dump(mode="json"),
        user_id=user.id,
    )
    db.commit()
    return result, False


def void_payment(
    db: Session,
    order_id: uuid.UUID,
    payment_id: uuid.UUID,
    *,
    reason: str,
    user: User,
    override_token: str | None,
    ctx: RequestContext,
) -> tuple[Order, list[ApiWarning]]:
    """Corrige une erreur de saisie : le paiement reste en base (`VOIDED`), la commande
    redevient `PARTIALLY_PAID` ou `OPEN`. Uniquement dans la session en cours (Z non figé)."""
    order = orders_repo.get_for_update(db, order_id)
    if order is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    payment = payments_repo.get(db, payment_id)
    if payment is None or payment.order_id != order.id:
        raise NotFoundError(meta={"payment_id": str(payment_id)})

    def refuse(reason_code: str, **meta: Any) -> DomainError:
        return PaymentNotVoidableError(
            meta={"payment_id": str(payment_id), "reason": reason_code, **meta}
        )

    if payment.status == PaymentStatus.VOIDED:
        raise refuse("already_voided")
    if order.status not in (*ACTIVE_ORDER_STATUSES, OrderStatus.PAID):
        raise refuse("order_status", status=order.status)
    session = auth_service.current_open_session(db)
    if session is None or payment.cash_session_id != session.id:
        raise refuse("session_closed")
    granted_by = order_service.authorize_manager(db, user, override_token, VOID_ACTION)
    before_status = order.status
    payment.status = PaymentStatus.VOIDED
    payment.voided_at = utcnow()
    payment.voided_by = user.id
    payment.void_reason = reason
    _apply_paid(db, order, user)
    audit_service.log(
        db,
        VOID_ACTION,
        ctx=ctx,
        user_id=user.id,
        acting_as_user_id=granted_by,
        entity="payment",
        entity_id=payment.id,
        before={"status": PaymentStatus.CAPTURED, "order_status": before_status},
        after={
            "status": payment.status,
            "order_status": order.status,
            "method": payment.method,
            "amount_xof": payment.amount_xof,
        },
        reason=reason,
    )
    warnings: list[ApiWarning] = []
    document = fne_repo.sale_for_order(db, order.id)
    if document is not None and document.status != FneStatus.FAILED:
        warnings.append(
            ApiWarning(
                code="FNE_ALREADY_ISSUED",
                detail="La commande a déjà une FNE : si la vente est annulée, émettre un avoir.",
                meta={"document_id": str(document.id), "status": document.status},
            )
        )
    db.commit()
    return order, warnings
