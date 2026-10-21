"""FNE à la demande (PLAN-FNE D1) : émission, avoir, renvoi, résolution des cas incertains.

Règle centrale (D5) : l'API FNE n'est pas idempotente. Un document est commité en `SUBMITTING`
**avant** l'appel ; si l'issue est inconnue (délai dépassé, 500…), il reste `SUBMITTING` avec
`is_uncertain` et n'est jamais renvoyé sans qu'un responsable ait vérifié l'espace FNE.
Seuls les documents en file (`QUEUED` : rien n'a été certifié) repartent automatiquement
(`retry_next_due`, en boucle dans `caisse.cli fne-worker`).
"""

import uuid
from datetime import date, timedelta
from typing import Any

import structlog
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.domain import fne
from caisse.domain.enums import FneDocumentType, FneStatus, OrderStatus, PaymentMethod
from caisse.domain.ports import (
    FneAuthError,
    FneError,
    FneProvider,
    FneRejectedError,
    FneResult,
    FneUnavailableError,
)
from caisse.errors import (
    FneDocumentStateError,
    FneInvalidDataError,
    FneNotConfiguredError,
    FneOrderNotPaidError,
    FneRefundExceedsError,
    NotFoundError,
    ValidationError,
)
from caisse.models.catalog import Product
from caisse.models.customer import Customer
from caisse.models.fne import FneDocument
from caisse.models.order import Order
from caisse.models.user import User
from caisse.repositories import customers as customers_repo
from caisse.repositories import fne as fne_repo
from caisse.repositories import orders as orders_repo
from caisse.repositories import settings as settings_repo
from caisse.schemas.common import ApiWarning
from caisse.schemas.fne import FiscalGroupLine, FneDailySummaryOut, FneDocumentOut
from caisse.security import utcnow
from caisse.services import audit_service
from caisse.services.audit_service import RequestContext

log = structlog.get_logger()

# Backoff des renvois automatiques (01-BACKEND §5.7), plafonné au dernier palier
RETRY_DELAYS = (
    timedelta(minutes=1),
    timedelta(minutes=5),
    timedelta(minutes=15),
    timedelta(hours=1),
)
WORKER_CTX = RequestContext(device_id="fne-worker")
DEFAULT_WALK_IN = {"company_name": "CLIENT DIVERS", "phone": "", "email": ""}
MEASUREMENT_UNIT = "U"


# --- Lecture -----------------------------------------------------------------------------


def to_out(db: Session, doc: FneDocument) -> FneDocumentOut:
    numbers = fne_repo.order_numbers(db, {doc.order_id} if doc.order_id else set())
    return _out(doc, numbers)


def to_out_many(db: Session, docs: list[FneDocument]) -> list[FneDocumentOut]:
    numbers = fne_repo.order_numbers(db, {d.order_id for d in docs if d.order_id})
    return [_out(doc, numbers) for doc in docs]


def _out(doc: FneDocument, numbers: dict[uuid.UUID, str]) -> FneDocumentOut:
    return FneDocumentOut(
        id=doc.id,
        type=doc.type,
        status=doc.status,
        is_uncertain=doc.is_uncertain,
        template=fne.FneTemplate(doc.template) if doc.template else None,
        order_id=doc.order_id,
        internal_reference=numbers.get(doc.order_id) if doc.order_id else None,
        customer_id=doc.customer_id,
        parent_document_id=doc.parent_document_id,
        external_number=doc.external_number,
        qr_payload=doc.qr_payload,
        fne_amount_ttc_xof=doc.fne_amount_ttc_xof,
        certified_at=doc.certified_at,
        attempts=doc.attempts,
        last_error=doc.last_error,
        next_retry_at=doc.next_retry_at,
        created_at=doc.created_at,
    )


def get_document(db: Session, document_id: uuid.UUID) -> FneDocument:
    doc = fne_repo.get(db, document_id)
    if doc is None:
        raise NotFoundError(meta={"document_id": str(document_id)})
    return doc


def get_for_order(db: Session, order_id: uuid.UUID) -> FneDocument:
    doc = fne_repo.sale_for_order(db, order_id)
    if doc is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    return doc


def get_duplicate(db: Session, document_id: uuid.UUID) -> FneDocument:
    doc = get_document(db, document_id)
    if doc.status is not FneStatus.CERTIFIED:
        raise FneDocumentStateError(
            meta={"document_id": str(doc.id), "status": doc.status, "reason": "not_certified"}
        )
    return doc


def warnings_for(db: Session, doc: FneDocument) -> list[ApiWarning]:
    warnings: list[ApiWarning] = []
    if doc.status is FneStatus.FAILED:
        warnings.append(ApiWarning(code="FNE_REJECTED", detail=doc.last_error))
    elif doc.is_uncertain:
        warnings.append(ApiWarning(code="FNE_UNCERTAIN", detail=doc.last_error))
    elif doc.status is FneStatus.QUEUED:
        warnings.append(
            ApiWarning(
                code="FNE_QUEUED",
                detail=doc.last_error,
                meta={
                    "next_retry_at": doc.next_retry_at.isoformat() if doc.next_retry_at else None
                },
            )
        )
    # seuil fixé par la DGI (`warning`) : le coût d'une facture n'est pas connu de la caisse
    if doc.low_balance_warning:
        warnings.append(
            ApiWarning(
                code="FNE_STICKER_LOW",
                detail="Solde FNE bas : recharger avant qu'il soit épuisé",
                meta={"balance_funds_xof": doc.balance_funds_xof},
            )
        )
    return warnings


def daily_summary(db: Session, business_date: date) -> FneDailySummaryOut:
    paid_count, gross = fne_repo.paid_orders_totals(db, business_date)
    certified_count, certified_ttc = fne_repo.certified_orders_totals(db, business_date)
    return FneDailySummaryOut(
        business_date=business_date,
        paid_orders=paid_count,
        gross_ttc_xof=gross,
        certified_orders=certified_count,
        certified_ttc_xof=certified_ttc,
        pending_documents=fne_repo.pending_for_date(db, business_date),
        by_fiscal_group=[
            FiscalGroupLine(group=group, quantity=qty, amount_xof=amount)
            for group, qty, amount in fne_repo.fiscal_group_totals(db, business_date)
        ],
    )


# --- Émission ----------------------------------------------------------------------------


def issue_for_order(
    db: Session,
    order_id: uuid.UUID,
    *,
    template: fne.FneTemplate,
    customer_id: uuid.UUID | None,
    payment_method: PaymentMethod | None,
    provider: FneProvider | None,
    user: User,
    ctx: RequestContext,
) -> tuple[FneDocument, bool]:
    """FNE de vente d'une commande soldée. Retourne `(document, envoyé)` : si une FNE existe
    déjà (et n'a pas été refusée), elle est renvoyée telle quelle, sans nouvel appel : un double
    clic ne certifie jamais deux fois. Une FNE refusée est reconstruite et renvoyée."""
    order = orders_repo.get_for_update(db, order_id)
    if order is None:
        raise NotFoundError(meta={"order_id": str(order_id)})
    existing = fne_repo.sale_for_order(db, order.id)
    if existing is not None and existing.status is not FneStatus.FAILED:
        db.rollback()
        return existing, False
    if order.status is not OrderStatus.PAID:
        raise FneOrderNotPaidError(meta={"order_id": str(order.id), "status": order.status})
    customer = _customer_for(db, template, customer_id)
    payload = _sale_payload(db, order, template, customer, payment_method, user, provider)

    if existing is not None:
        doc = existing
        doc.template, doc.customer_id, doc.payload = template.value, customer_id, payload
        doc.last_error = None
    else:
        doc = FneDocument(
            type=FneDocumentType.FNE,
            order_id=order.id,
            cash_session_id=order.cash_session_id,
            customer_id=customer_id,
            template=template.value,
            status=FneStatus.PENDING,
            payload=payload,
            created_by_user_id=user.id,
        )
        db.add(doc)
    try:
        db.flush()
    except IntegrityError:
        # course entre deux postes : l'index « une FNE de vente par commande » a tranché
        db.rollback()
        winner = fne_repo.sale_for_order(db, order_id)
        if winner is None:
            raise
        return winner, False
    audit_service.log(
        db,
        "fne.issue",
        ctx=ctx,
        user_id=user.id,
        entity="fne_document",
        entity_id=doc.id,
        after={"order_id": str(order.id), "template": template.value},
    )
    db.commit()
    _submit(db, doc, provider, user_id=user.id, ctx=ctx)
    return doc, True


def _customer_for(
    db: Session, template: fne.FneTemplate, customer_id: uuid.UUID | None
) -> Customer | None:
    if customer_id is None:
        if template is not fne.FneTemplate.B2C:
            raise FneInvalidDataError(
                "FNE_CUSTOMER_REQUIRED",
                f"Client entreprise obligatoire en {template.value}",
                meta={"template": template.value},
            )
        return None
    customer = customers_repo.get(db, customer_id)
    if customer is None:
        raise NotFoundError(meta={"customer_id": str(customer_id)})
    return customer


def _sale_payload(
    db: Session,
    order: Order,
    template: fne.FneTemplate,
    customer: Customer | None,
    payment_method: PaymentMethod | None,
    user: User,
    provider: FneProvider | None,
) -> dict[str, Any]:
    """`request` : corps exact envoyé à la FNE ; le reste sert aux avoirs et aux renvois.
    En mode manuel (pas de fournisseur), un instantané lisible suffit."""
    items = orders_repo.active_items(db, order.id)
    if provider is None:
        return {
            "mode": "manual",
            "template": template.value,
            "order_number": order.order_number,
            "total_ttc_xof": order.total_ttc_xof,
            "lines": [
                {
                    "description": i.product_name_snapshot,
                    "quantity": i.quantity,
                    "unit_price_xof": i.unit_price_xof,
                    "vat_rate": str(i.vat_rate),
                }
                for i in items
            ],
        }
    try:
        method = payment_method or fne.dominant_payment_method(
            fne_repo.captured_payments(db, order.id)
        )
        request = fne.build_sale_request(
            lines=[
                fne.FneLine(
                    description=item.product_name_snapshot,
                    quantity=item.quantity,
                    unit_price_ttc_xof=item.unit_price_xof,
                    vat_rate=item.vat_rate,
                    reference=_sku(db, item.product_id),
                    measurement_unit=MEASUREMENT_UNIT,
                )
                for item in items
            ],
            client=_client(db, customer, user),
            template=template,
            payment_method=fne.payment_method_code(method),
            issuer=_issuer(db),
        )
    except fne.FneMappingError as exc:
        raise FneInvalidDataError(exc.code, exc.detail, meta={"order_id": str(order.id)}) from None
    return {
        "request": fne.json_safe(request),
        "payment_method": method.value,
        "order_item_ids": [str(item.id) for item in items],
    }


def _sku(db: Session, product_id: uuid.UUID) -> str | None:
    product = db.get(Product, product_id)
    return product.sku if product is not None else None


def _issuer(db: Session) -> fne.FneIssuer:
    point_of_sale = str(settings_repo.get_value(db, "fne.point_of_sale", "") or "")
    establishment = str(settings_repo.get_value(db, "fne.establishment", "") or "")
    missing = [
        key
        for key, value in (
            ("fne.point_of_sale", point_of_sale),
            ("fne.establishment", establishment),
        )
        if not value.strip()
    ]
    if missing:
        raise FneNotConfiguredError(meta={"missing_settings": missing})
    return fne.FneIssuer(point_of_sale=point_of_sale, establishment=establishment)


def _client(db: Session, customer: Customer | None, user: User) -> fne.FneClient:
    """Client de passage paramétrable (`fne.walk_in_client`) ; un client entreprise sans
    téléphone ni e-mail reprend ceux du client de passage (champs exigés par la FNE)."""
    walk_in = {**DEFAULT_WALK_IN, **(settings_repo.get_value(db, "fne.walk_in_client", {}) or {})}
    if customer is None:
        return fne.FneClient(
            company_name=str(walk_in["company_name"]),
            phone=str(walk_in["phone"]),
            email=str(walk_in["email"]),
            seller_name=user.full_name,
        )
    return fne.FneClient(
        company_name=customer.company_name,
        phone=customer.phone or str(walk_in["phone"]),
        email=customer.email or str(walk_in["email"]),
        ncc=customer.ncc,
        seller_name=user.full_name,
    )


# --- Avoir -------------------------------------------------------------------------------


def refund(
    db: Session,
    document_id: uuid.UUID,
    *,
    lines: list[tuple[uuid.UUID, int]],
    provider: FneProvider | None,
    user: User,
    ctx: RequestContext,
) -> FneDocument:
    """Avoir FNE (total ou partiel) sur une FNE certifiée par l'API. Les quantités déjà reprises
    par des avoirs non refusés sont déduites."""
    parent = fne_repo.get_for_update(db, document_id)
    if parent is None:
        raise NotFoundError(meta={"document_id": str(document_id)})
    if (
        parent.type is not FneDocumentType.FNE
        or parent.status is not FneStatus.CERTIFIED
        or not parent.fne_invoice_id
        or not parent.items_map
        or provider is None
    ):
        raise FneDocumentStateError(
            meta={
                "document_id": str(parent.id),
                "status": parent.status,
                "reason": "not_refundable",
            }
        )
    certified = {entry["order_item_id"]: entry for entry in parent.items_map}
    already: dict[str, int] = {}
    for previous in fne_repo.refunds_of(db, parent.id):
        if previous.status is FneStatus.FAILED:
            continue
        for line in previous.payload.get("lines", []):
            already[line["order_item_id"]] = (
                already.get(line["order_item_id"], 0) + line["quantity"]
            )

    requested: dict[str, int] = {}
    for order_item_id, quantity in lines:
        key = str(order_item_id)
        requested[key] = requested.get(key, 0) + quantity
    refund_lines = []
    for key, quantity in requested.items():
        entry = certified.get(key)
        if entry is None:
            raise NotFoundError(meta={"order_item_id": key})
        available = int(entry["quantity"]) - already.get(key, 0)
        if quantity > available:
            raise FneRefundExceedsError(
                meta={"order_item_id": key, "requested": quantity, "available": available}
            )
        refund_lines.append(
            {"order_item_id": key, "fne_item_id": entry["fne_item_id"], "quantity": quantity}
        )

    doc = FneDocument(
        type=FneDocumentType.REFUND,
        order_id=parent.order_id,
        cash_session_id=parent.cash_session_id,
        customer_id=parent.customer_id,
        template=parent.template,
        parent_document_id=parent.id,
        status=FneStatus.PENDING,
        payload={
            "fne_invoice_id": parent.fne_invoice_id,
            "request": fne.build_refund_request(
                [(line["fne_item_id"], line["quantity"]) for line in refund_lines]
            ),
            "lines": refund_lines,
        },
        created_by_user_id=user.id,
    )
    db.add(doc)
    db.flush()
    audit_service.log(
        db,
        "fne.refund",
        ctx=ctx,
        user_id=user.id,
        entity="fne_document",
        entity_id=doc.id,
        after={"parent_document_id": str(parent.id), "lines": refund_lines},
    )
    db.commit()
    _submit(db, doc, provider, user_id=user.id, ctx=ctx)
    return doc


# --- Renvoi et résolution ----------------------------------------------------------------


def retry(
    db: Session,
    document_id: uuid.UUID,
    *,
    provider: FneProvider | None,
    user: User,
    ctx: RequestContext,
) -> FneDocument:
    """Renvoi manuel d'un document en file (`QUEUED`), refusé (`FAILED`, reconstruit à partir de
    la commande et du client, éventuellement corrigés) ou resté `PENDING`. Un document incertain
    passe d'abord par `resolve`."""
    doc = fne_repo.get_for_update(db, document_id)
    if doc is None:
        raise NotFoundError(meta={"document_id": str(document_id)})
    if doc.is_uncertain:
        _state_error(doc, "uncertain")
    if doc.status not in (FneStatus.QUEUED, FneStatus.FAILED, FneStatus.PENDING):
        _state_error(doc, "not_retryable")
    if doc.status is FneStatus.FAILED and doc.type is FneDocumentType.FNE and doc.order_id:
        order = orders_repo.get(db, doc.order_id)
        assert order is not None
        template = fne.FneTemplate(doc.template or fne.FneTemplate.B2C.value)
        stored_method = doc.payload.get("payment_method")
        doc.payload = _sale_payload(
            db,
            order,
            template,
            _customer_for(db, template, doc.customer_id),
            PaymentMethod(stored_method) if stored_method else None,
            user,
            provider,
        )
    audit_service.log(
        db,
        "fne.retry",
        ctx=ctx,
        user_id=user.id,
        entity="fne_document",
        entity_id=doc.id,
        before={"status": doc.status, "last_error": doc.last_error},
    )
    db.commit()
    _submit(db, doc, provider, user_id=user.id, ctx=ctx)
    return doc


def retry_next_due(db: Session, provider: FneProvider) -> FneDocument | None:
    """Renvoi automatique du plus ancien document en file dont l'échéance est passée ; `None`
    s'il n'y en a pas. Un nouvel échec certain le remet en file au palier suivant de
    `RETRY_DELAYS`. Les documents refusés ou incertains restent manuels."""
    doc = fne_repo.next_due(db, utcnow())
    if doc is None:
        db.rollback()  # referme la transaction de la recherche
        return None
    _submit(db, doc, provider, user_id=None, ctx=WORKER_CTX)
    return doc


def resolve(
    db: Session,
    document_id: uuid.UUID,
    *,
    is_certified: bool,
    external_number: str | None,
    qr_payload: str | None,
    provider: FneProvider | None,
    user: User,
    ctx: RequestContext,
) -> FneDocument:
    """Clôture d'un cas incertain après vérification dans l'espace FNE : certifiée (n° relevé)
    ou non certifiée (renvoyée). Une FNE certifiée ainsi n'a pas les identifiants FNE requis
    pour un avoir par API."""
    doc = fne_repo.get_for_update(db, document_id)
    if doc is None:
        raise NotFoundError(meta={"document_id": str(document_id)})
    if not doc.is_uncertain:
        _state_error(doc, "not_uncertain")
    before = {"status": doc.status, "last_error": doc.last_error}
    if is_certified:
        if not (external_number or "").strip():
            raise ValidationError(
                "N° FNE obligatoire",
                meta={"fields": [{"loc": ["body", "external_number"], "type": "missing"}]},
            )
        doc.status = FneStatus.CERTIFIED
        doc.external_number = (external_number or "").strip()
        doc.qr_payload = qr_payload
        doc.certified_at = utcnow()
        doc.is_uncertain = False
    else:
        doc.is_uncertain = False
        doc.status = FneStatus.PENDING
    audit_service.log(
        db,
        "fne.resolve",
        ctx=ctx,
        user_id=user.id,
        entity="fne_document",
        entity_id=doc.id,
        before=before,
        after={"is_certified": is_certified, "external_number": doc.external_number},
    )
    db.commit()
    if not is_certified:
        _submit(db, doc, provider, user_id=user.id, ctx=ctx)
    return doc


def _state_error(doc: FneDocument, reason: str) -> None:
    raise FneDocumentStateError(
        meta={
            "document_id": str(doc.id),
            "status": doc.status,
            "is_uncertain": doc.is_uncertain,
            "reason": reason,
        }
    )


# --- Appel FNE ---------------------------------------------------------------------------


def _submit(
    db: Session,
    doc: FneDocument,
    provider: FneProvider | None,
    *,
    user_id: uuid.UUID | None,
    ctx: RequestContext,
) -> None:
    if provider is None:  # FNE_PROVIDER=manual : saisie dans l'application FNE
        doc.status = FneStatus.MANUAL
        db.commit()
        return
    # commité AVANT l'appel : si le processus meurt pendant l'appel, le document reste
    # visible en SUBMITTING et ne sera pas renvoyé à l'aveugle
    doc.status = FneStatus.SUBMITTING
    doc.is_uncertain = False
    doc.attempts += 1
    doc.next_retry_at = None
    db.commit()

    timeout = get_settings().fne_sync_timeout_seconds
    request: dict[str, Any] = doc.payload["request"]
    try:
        if doc.type is FneDocumentType.REFUND:
            result = provider.refund(doc.payload["fne_invoice_id"], request, timeout=timeout)
        else:
            result = provider.sign(request, timeout=timeout)
    except FneRejectedError as exc:
        doc.status = FneStatus.FAILED
        _record_error(doc, exc)
    except (FneAuthError, FneUnavailableError) as exc:
        doc.status = FneStatus.QUEUED
        doc.next_retry_at = utcnow() + RETRY_DELAYS[min(doc.attempts, len(RETRY_DELAYS)) - 1]
        _record_error(doc, exc)
    except FneError as exc:  # FneUncertainError
        doc.is_uncertain = True
        _record_error(doc, exc)
    else:
        _record_success(doc, result)
    audit_service.log(
        db,
        "fne.submit",
        ctx=ctx,
        user_id=user_id,
        entity="fne_document",
        entity_id=doc.id,
        after={
            "status": doc.status,
            "is_uncertain": doc.is_uncertain,
            "external_number": doc.external_number,
            "attempts": doc.attempts,
        },
    )
    db.commit()
    log.info(
        "fne_submitted",
        document_id=str(doc.id),
        status=doc.status,
        is_uncertain=doc.is_uncertain,
        attempts=doc.attempts,
    )


def _record_error(doc: FneDocument, exc: FneError) -> None:
    doc.last_error = f"{type(exc).__name__}: {exc}"[:1000]
    if isinstance(exc.body, dict):
        doc.raw_response = exc.body


def _record_success(doc: FneDocument, result: FneResult) -> None:
    doc.status = FneStatus.CERTIFIED
    doc.external_number = result.external_number
    doc.qr_payload = result.qr_payload
    doc.raw_response = result.raw
    doc.certified_at = utcnow()
    doc.last_error = None
    doc.fne_amount_ttc_xof = result.amount_ttc
    doc.balance_funds_xof = result.balance_funds_xof
    doc.low_balance_warning = result.low_balance_warning
    if doc.type is FneDocumentType.FNE:
        doc.fne_invoice_id = result.invoice_id
        order_item_ids: list[str] = doc.payload.get("order_item_ids", [])
        if len(result.items) == len(order_item_ids):
            # la FNE renvoie les articles dans l'ordre d'envoi
            doc.items_map = [
                {"order_item_id": oid, "fne_item_id": item.id, "quantity": item.quantity}
                for oid, item in zip(order_item_ids, result.items, strict=True)
            ]
        else:
            log.warning(
                "fne_items_mismatch",
                document_id=str(doc.id),
                sent=len(order_item_ids),
                received=len(result.items),
            )
