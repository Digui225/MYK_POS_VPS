"""Approvisionnement : demande d'achat de l'acheteur → validation → décaissement → réception.

L'acheteur ne voit jamais un prix : il saisit des quantités et reçoit le total à lui remettre,
calculé au dernier prix d'achat de chaque article (à défaut, son coût moyen). Le responsable
peut corriger quantités et prix à la validation. La réception crée les entrées de stock au
prix réellement payé, et calcule la monnaie à rendre.
"""

import uuid
from decimal import Decimal

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.domain import stock_rules
from caisse.domain.enums import PurchaseStatus, StockArticleCategory
from caisse.errors import (
    IdempotencyConflictError,
    NotFoundError,
    PurchaseStateError,
    ValidationError,
)
from caisse.models.purchase import PurchaseRequest, PurchaseRequestLine
from caisse.models.user import User
from caisse.repositories import purchases as purchases_repo
from caisse.repositories import stock as stock_repo
from caisse.schemas.common import UserOut
from caisse.schemas.purchases import (
    BuyerLineOut,
    BuyerPurchaseOut,
    BuyerPurchaseSummaryOut,
    PurchaseApprove,
    PurchaseArticleOut,
    PurchaseCreate,
    PurchaseLineOut,
    PurchaseOut,
    PurchasePendingOut,
    PurchaseReceive,
    PurchaseSummaryOut,
)
from caisse.security import utcnow
from caisse.sequences import next_value
from caisse.services import audit_service, stock_service
from caisse.services.audit_service import RequestContext

NUMBER_PREFIX = "ACH"


# --- Lecture -----------------------------------------------------------------------------


def articles(
    db: Session, *, category: StockArticleCategory | None, search: str | None
) -> list[PurchaseArticleOut]:
    """Articles actifs, sans coût ni valeur : la liste de courses de l'acheteur."""
    rows = stock_repo.list_articles(db, category=category, search=search)
    return [
        PurchaseArticleOut(
            id=a.id,
            name=a.name,
            category=a.category,
            unit=a.unit,
            quantity=float(a.quantity),
            is_low=stock_rules.is_below_threshold(a.quantity, a.alert_threshold),
        )
        for a in rows
    ]


def get_request(db: Session, request_id: uuid.UUID) -> PurchaseRequest:
    request = purchases_repo.get(db, request_id)
    if request is None:
        raise NotFoundError(meta={"purchase_id": str(request_id)})
    return request


def get_own_request(db: Session, request_id: uuid.UUID, user: User) -> PurchaseRequest:
    """Demande de l'acheteur connecté ; celle d'un autre est introuvable pour lui."""
    request = get_request(db, request_id)
    if request.requested_by_user_id != user.id:
        raise NotFoundError(meta={"purchase_id": str(request_id)})
    return request


def pending(db: Session) -> PurchasePendingOut:
    counts = purchases_repo.count_by_status(db)
    return PurchasePendingOut(
        submitted=counts.get(PurchaseStatus.SUBMITTED, 0),
        approved=counts.get(PurchaseStatus.APPROVED, 0),
        disbursed=counts.get(PurchaseStatus.DISBURSED, 0),
    )


def _line_quantity(line: PurchaseRequestLine) -> Decimal:
    return line.approved_quantity if line.approved_quantity is not None else line.requested_quantity


def _line_amount(line: PurchaseRequestLine) -> int:
    return stock_rules.value_xof(_line_quantity(line), line.unit_price_xof)


def _change_due(request: PurchaseRequest) -> int | None:
    if request.disbursed_xof is None or request.received_total_xof is None:
        return None
    return request.disbursed_xof - request.received_total_xof


def _amount_to_give(request: PurchaseRequest) -> int:
    if request.approved_total_xof is not None:
        return request.approved_total_xof
    return request.estimated_total_xof


def _float(value: Decimal | None) -> float | None:
    return float(value) if value is not None else None


def buyer_summary(request: PurchaseRequest) -> BuyerPurchaseSummaryOut:
    return BuyerPurchaseSummaryOut(
        id=request.id,
        number=request.number,
        status=request.status,
        note=request.note,
        amount_xof=_amount_to_give(request),
        disbursed_xof=request.disbursed_xof,
        received_total_xof=request.received_total_xof,
        change_due_xof=_change_due(request),
        closed_reason=request.closed_reason,
        created_at=request.created_at,
        updated_at=request.updated_at,
    )


def buyer_out(db: Session, request: PurchaseRequest) -> BuyerPurchaseOut:
    return BuyerPurchaseOut(
        **buyer_summary(request).model_dump(),
        lines=[
            BuyerLineOut(
                id=line.id,
                article_id=article.id,
                article_name=article.name,
                unit=article.unit,
                requested_quantity=float(line.requested_quantity),
                approved_quantity=_float(line.approved_quantity),
                received_quantity=_float(line.received_quantity),
            )
            for line, article in purchases_repo.lines(db, request.id)
        ],
    )


def summaries(db: Session, requests: list[PurchaseRequest]) -> list[PurchaseSummaryOut]:
    users = purchases_repo.users_by_id(
        db,
        [
            user_id
            for r in requests
            for user_id in (
                r.requested_by_user_id,
                r.approved_by_user_id,
                r.disbursed_by_user_id,
                r.received_by_user_id,
                r.closed_by_user_id,
            )
        ],
    )
    counts = purchases_repo.line_counts(db, [r.id for r in requests])

    def user(user_id: uuid.UUID | None) -> UserOut | None:
        return UserOut.model_validate(users[user_id]) if user_id is not None else None

    return [
        PurchaseSummaryOut(
            id=r.id,
            number=r.number,
            status=r.status,
            requested_by=UserOut.model_validate(users[r.requested_by_user_id]),
            note=r.note,
            estimated_total_xof=r.estimated_total_xof,
            approved_total_xof=r.approved_total_xof,
            approved_by=user(r.approved_by_user_id),
            approved_at=r.approved_at,
            disbursed_xof=r.disbursed_xof,
            disbursed_by=user(r.disbursed_by_user_id),
            disbursed_at=r.disbursed_at,
            received_total_xof=r.received_total_xof,
            received_by=user(r.received_by_user_id),
            received_at=r.received_at,
            supplier=r.supplier,
            change_due_xof=_change_due(r),
            closed_reason=r.closed_reason,
            closed_by=user(r.closed_by_user_id),
            closed_at=r.closed_at,
            line_count=counts.get(r.id, 0),
            created_at=r.created_at,
            updated_at=r.updated_at,
        )
        for r in requests
    ]


def to_out(db: Session, request: PurchaseRequest) -> PurchaseOut:
    return PurchaseOut(
        **summaries(db, [request])[0].model_dump(),
        lines=[
            PurchaseLineOut(
                id=line.id,
                article_id=article.id,
                article_name=article.name,
                category=article.category,
                unit=article.unit,
                requested_quantity=float(line.requested_quantity),
                approved_quantity=_float(line.approved_quantity),
                unit_price_xof=float(line.unit_price_xof),
                price_missing=line.unit_price_xof == 0,
                amount_xof=_line_amount(line),
                received_quantity=_float(line.received_quantity),
                received_cost_xof=line.received_cost_xof,
            )
            for line, article in purchases_repo.lines(db, request.id)
        ],
    )


# --- Acheteur ----------------------------------------------------------------------------


def create(
    db: Session,
    body: PurchaseCreate,
    *,
    key: str,
    path: str,
    user: User,
    ctx: RequestContext,
) -> tuple[BuyerPurchaseOut, bool]:
    """Envoi d'une demande, au dernier prix d'achat de chaque article (à défaut, son coût
    moyen). Idempotent : un double envoi renvoie la demande d'origine. Retourne (demande vue
    par l'acheteur, rejouée)."""
    request_hash = idempotency.hash_request(body)
    replay = idempotency.find_replay(db, key, method="POST", path=path, request_hash=request_hash)
    if replay is not None:
        return BuyerPurchaseOut.model_validate(replay), True

    article_ids = [line.article_id for line in body.lines]
    found = {a.id: a for a in purchases_repo.active_articles(db, article_ids)}
    missing = [str(i) for i in article_ids if i not in found]
    if missing:
        raise NotFoundError(meta={"article_ids": missing})
    last_costs = purchases_repo.last_purchase_costs(db, article_ids)

    request = PurchaseRequest(
        number=f"{NUMBER_PREFIX}-{next_value(db, 'purchase'):04d}",
        status=PurchaseStatus.SUBMITTED,
        requested_by_user_id=user.id,
        note=body.note,
        estimated_total_xof=0,
    )
    db.add(request)
    db.flush()
    lines = [
        PurchaseRequestLine(
            request_id=request.id,
            article_id=line.article_id,
            requested_quantity=stock_rules.quantize_qty(line.quantity),
            unit_price_xof=stock_rules.quantize_cost(
                last_costs.get(line.article_id, found[line.article_id].avg_cost_xof)
            ),
        )
        for line in body.lines
    ]
    db.add_all(lines)
    request.estimated_total_xof = sum(_line_amount(line) for line in lines)
    db.flush()
    audit_service.log(
        db,
        "purchase.create",
        ctx=ctx,
        user_id=user.id,
        entity="purchase_request",
        entity_id=request.id,
        after={
            "number": request.number,
            "lines": len(lines),
            "estimated_total_xof": request.estimated_total_xof,
        },
    )
    result = buyer_out(db, request)
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
        return BuyerPurchaseOut.model_validate(replay), True
    return result, False


def cancel(
    db: Session, request_id: uuid.UUID, *, reason: str | None, user: User, ctx: RequestContext
) -> PurchaseRequest:
    """Retrait par l'acheteur, tant que la demande n'est pas validée."""
    request = _lock(db, request_id)
    if request.requested_by_user_id != user.id:
        raise NotFoundError(meta={"purchase_id": str(request_id)})
    _expect(request, PurchaseStatus.SUBMITTED)
    _close(request, PurchaseStatus.CANCELLED, reason, user)
    _log(db, "purchase.cancel", request, user, ctx, {"reason": reason})
    db.commit()
    return request


# --- Responsable -------------------------------------------------------------------------


def approve(
    db: Session, request_id: uuid.UUID, body: PurchaseApprove, *, user: User, ctx: RequestContext
) -> PurchaseRequest:
    """Validation, avec corrections éventuelles (quantité, prix d'une unité) ; une ligne non
    corrigée est validée telle que demandée."""
    request = _lock(db, request_id)
    _expect(request, PurchaseStatus.SUBMITTED)
    lines = {line.id: line for line, _ in purchases_repo.lines(db, request.id)}
    unknown = [str(c.line_id) for c in body.lines if c.line_id not in lines]
    if unknown:
        raise NotFoundError(meta={"line_ids": unknown})
    corrections = {c.line_id: c for c in body.lines}
    for line_id, line in lines.items():
        correction = corrections.get(line_id)
        quantity = correction.quantity if correction else None
        price = correction.unit_price_xof if correction else None
        line.approved_quantity = stock_rules.quantize_qty(
            quantity if quantity is not None else line.requested_quantity
        )
        if price is not None:
            line.unit_price_xof = stock_rules.quantize_cost(price)
    if all(line.approved_quantity == 0 for line in lines.values()):
        raise ValidationError(
            "Aucune quantité validée : refuser la demande plutôt",
            meta={"fields": [{"loc": ["body", "lines"], "type": "all_zero"}]},
        )
    request.status = PurchaseStatus.APPROVED
    request.approved_total_xof = sum(_line_amount(line) for line in lines.values())
    request.approved_by_user_id = user.id
    request.approved_at = utcnow()
    _log(
        db,
        "purchase.approve",
        request,
        user,
        ctx,
        {"approved_total_xof": request.approved_total_xof, "corrections": len(corrections)},
    )
    db.commit()
    return request


def reject(
    db: Session, request_id: uuid.UUID, *, reason: str, user: User, ctx: RequestContext
) -> PurchaseRequest:
    """Refus, avant que l'argent soit remis."""
    request = _lock(db, request_id)
    _expect(request, PurchaseStatus.SUBMITTED, PurchaseStatus.APPROVED)
    _close(request, PurchaseStatus.REJECTED, reason, user)
    _log(db, "purchase.reject", request, user, ctx, {"reason": reason})
    db.commit()
    return request


def disburse(
    db: Session,
    request_id: uuid.UUID,
    *,
    amount_xof: int | None,
    user: User,
    ctx: RequestContext,
) -> PurchaseRequest:
    """Argent remis à l'acheteur : le total validé, ou le montant indiqué (arrondi, prix
    manquants…)."""
    request = _lock(db, request_id)
    _expect(request, PurchaseStatus.APPROVED)
    amount = amount_xof if amount_xof is not None else request.approved_total_xof
    if not amount:
        raise ValidationError(
            "Total validé nul (prix inconnus) : indiquer le montant remis",
            meta={"fields": [{"loc": ["body", "amount_xof"], "type": "missing"}]},
        )
    request.status = PurchaseStatus.DISBURSED
    request.disbursed_xof = amount
    request.disbursed_by_user_id = user.id
    request.disbursed_at = utcnow()
    _log(db, "purchase.disburse", request, user, ctx, {"disbursed_xof": amount})
    db.commit()
    return request


def receive(
    db: Session, request_id: uuid.UUID, body: PurchaseReceive, *, user: User, ctx: RequestContext
) -> PurchaseRequest:
    """Retour des courses : une entrée de stock par article acheté, au prix payé. Une ligne
    validée absente du corps compte comme non trouvée."""
    request = _lock(db, request_id)
    _expect(request, PurchaseStatus.DISBURSED)
    lines = {line.id: line for line, _ in purchases_repo.lines(db, request.id)}
    received = {r.line_id: r for r in body.lines}
    unknown = [str(i) for i in received if i not in lines]
    if unknown:
        raise NotFoundError(meta={"line_ids": unknown})
    not_approved = [str(i) for i in received if lines[i].approved_quantity == 0]
    if not_approved:
        raise ValidationError(
            "Ligne retirée à la validation",
            meta={
                "fields": [{"loc": ["body", "lines"], "type": "not_approved"}],
                "line_ids": not_approved,
            },
        )

    day = stock_service.business_day(db, body.business_date)
    articles = stock_service.lock_existing(db, [line.article_id for line in lines.values()])
    total = 0
    for line_id, line in lines.items():
        entry = received.get(line_id)
        line.received_quantity = stock_rules.quantize_qty(entry.quantity) if entry else Decimal(0)
        line.received_cost_xof = entry.total_cost_xof if entry else 0
        total += line.received_cost_xof
        if line.received_quantity > 0:
            movement = stock_service.record_purchase(
                db,
                articles[line.article_id],
                line.received_quantity,
                Decimal(line.received_cost_xof) / line.received_quantity,
                business_date=day,
                user_id=user.id,
                supplier=body.supplier,
                reason=f"Demande d'achat {request.number}",
            )
            db.flush()
            line.stock_movement_id = movement.id
    request.status = PurchaseStatus.RECEIVED
    request.received_total_xof = total
    request.received_by_user_id = user.id
    request.received_at = utcnow()
    request.supplier = body.supplier
    _log(
        db,
        "purchase.receive",
        request,
        user,
        ctx,
        {"received_total_xof": total, "change_due_xof": _change_due(request)},
    )
    db.commit()
    return request


# --- Outils ------------------------------------------------------------------------------


def _lock(db: Session, request_id: uuid.UUID) -> PurchaseRequest:
    request = purchases_repo.get_for_update(db, request_id)
    if request is None:
        raise NotFoundError(meta={"purchase_id": str(request_id)})
    return request


def _expect(request: PurchaseRequest, *allowed: PurchaseStatus) -> None:
    if request.status not in allowed:
        raise PurchaseStateError(
            meta={
                "purchase_id": str(request.id),
                "status": request.status,
                "expected": [s.value for s in allowed],
            }
        )


def _close(
    request: PurchaseRequest, status: PurchaseStatus, reason: str | None, user: User
) -> None:
    request.status = status
    request.closed_reason = reason
    request.closed_by_user_id = user.id
    request.closed_at = utcnow()


def _log(
    db: Session,
    action: str,
    request: PurchaseRequest,
    user: User,
    ctx: RequestContext,
    after: dict[str, object],
) -> None:
    audit_service.log(
        db,
        action,
        ctx=ctx,
        user_id=user.id,
        entity="purchase_request",
        entity_id=request.id,
        after={"number": request.number, "status": request.status, **after},
    )
