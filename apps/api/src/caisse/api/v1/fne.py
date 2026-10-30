from datetime import date, datetime, timezone
from typing import Annotated, Any, Optional

from fastapi import APIRouter, Depends, Query, Request, Response, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.database import get_db
from caisse.deps import (
    DbSession,
    Paging,
    Responsable,
    get_current_user,
    get_fne_provider,
    require_role,
)
from caisse.idempotency import OptionalIdempotencyKey
from caisse.models.user import User
from caisse.pagination import split
from caisse.repositories import fne as fne_repo
from caisse.schemas.common import Page
from caisse.schemas.fne import (
    FneDailySummaryOut,
    FneDocumentOut,
    FneDocumentResult,
    FneGenerateRequest,
    FneIssueIn,
    FnePendingCountOut,
    FneRefundIn,
    FneResolveIn,
)
from caisse.services import fne_service

router = APIRouter(tags=["FNE"])


@router.post(
    "/orders/{order_id}/fne",
    response_model=FneDocumentResult,
    status_code=status.HTTP_201_CREATED,
    summary="Émettre la FNE d'une commande soldée",
)
def issue(
    order_id: str,
    body: FneIssueIn,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
    provider: Any = Depends(get_fne_provider),
) -> FneDocumentResult:
    """FNE à la demande (DGI CI)."""
    request_hash = idempotency.hash_request(body)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return FneDocumentResult.model_validate(replay)

    doc, submitted = fne_service.issue_for_order(
        db,
        order_id,
        template=body.template,
        customer_id=body.customer_id,
        payment_method=body.payment_method,
        provider=provider,
        user=user,
    )
    if not submitted:
        response.status_code = status.HTTP_200_OK

    result = FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=201 if submitted else 200,
            body=result.model_dump(mode="json"),
            user_id=user.id,
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
                return FneDocumentResult.model_validate(replay)
            raise

    return result


@router.get("/orders/{order_id}/fne", response_model=FneDocumentOut, summary="FNE d'une commande")
def get_for_order(
    order_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> FneDocumentOut:
    """FNE de vente de la commande."""
    return fne_service.to_out(db, fne_service.get_for_order(db, order_id))


@router.get("/fne/documents", response_model=Page[FneDocumentOut], summary="Documents FNE (suivi)")
def list_documents(
    _: Responsable,
    db: DbSession,
    page: Paging,
    status_filter: Annotated[
        str | None, Query(alias="status", description="Filtrer sur un statut")
    ] = None,
    business_date: Annotated[
        date | None, Query(description="Journée comptable de la commande")
    ] = None,
) -> Page[FneDocumentOut]:
    """Les plus récents en premier, par pages de `limit` : `next_cursor` donne la suivante."""
    rows = fne_repo.list_documents(db, status=status_filter, business_date=business_date, page=page)
    docs, next_cursor = split(rows, page, lambda d: (d.created_at, d.id))
    return Page(items=fne_service.to_out_many(db, docs), next_cursor=next_cursor)



@router.post(
    "/fne/documents/{document_id}/retry",
    response_model=FneDocumentResult,
    summary="Renvoyer un document FNE",
)
def retry(
    document_id: str,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    db: Session = Depends(get_db),
    user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    provider: Any = Depends(get_fne_provider),
) -> FneDocumentResult:
    """Renvoie un document en QUEUED ou FAILED."""
    request_hash = idempotency.hash_request(None)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return FneDocumentResult.model_validate(replay)

    doc = fne_service.retry(db, document_id, provider=provider, user=user)
    result = FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=200,
            body=result.model_dump(mode="json"),
            user_id=user.id,
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
                return FneDocumentResult.model_validate(replay)
            raise

    return result


@router.post(
    "/fne/documents/{document_id}/resolve",
    response_model=FneDocumentResult,
    summary="Trancher un document FNE incertain",
)
def resolve(
    document_id: str,
    body: FneResolveIn,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    db: Session = Depends(get_db),
    user: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    provider: Any = Depends(get_fne_provider),
) -> FneDocumentResult:
    """Tranche un cas incertain après vérification dans l'espace FNE."""
    request_hash = idempotency.hash_request(body)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return FneDocumentResult.model_validate(replay)

    doc = fne_service.resolve(
        db,
        document_id,
        is_certified=body.is_certified,
        external_number=body.external_number,
        qr_payload=body.qr_payload,
        provider=provider,
        user=user,
    )
    result = FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )

    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=200,
            body=result.model_dump(mode="json"),
            user_id=user.id,
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
                return FneDocumentResult.model_validate(replay)
            raise

    return result


@router.post(
    "/fne/documents/{document_id}/refund",
    response_model=FneDocumentResult,
    status_code=status.HTTP_201_CREATED,
    summary="Émettre un avoir FNE",
)
def refund(
    document_id: str,
    body: FneRefundIn,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    db: Session = Depends(get_db),
    user: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    provider: Any = Depends(get_fne_provider),
) -> FneDocumentResult:
    """Avoir total ou partiel sur une FNE certifiée."""
    request_hash = idempotency.hash_request(body)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return FneDocumentResult.model_validate(replay)

    doc = fne_service.refund(
        db,
        document_id,
        lines=[(line.order_item_id, line.quantity) for line in body.items],
        provider=provider,
        user=user,
    )
    result = FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
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
            user_id=user.id,
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
                return FneDocumentResult.model_validate(replay)
            raise

    return result


@router.get(
    "/fne/documents/{document_id}/duplicate",
    response_model=FneDocumentOut,
    summary="Duplicata d'une FNE certifiée",
)
def duplicate(
    document_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> FneDocumentOut:
    """Duplicata d'une facture certifiée."""
    return fne_service.to_out(db, fne_service.get_duplicate(db, document_id))


@router.get(
    "/fne/pending-count",
    response_model=FnePendingCountOut,
    summary="Compteur de la barre d'état",
)
def pending_count(
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
    business_date: Optional[date] = Query(None, description="Filtrer par journée comptable"),
) -> FnePendingCountOut:
    """Nombre de documents en attente d'une action."""
    pending, uncertain, failed = fne_repo.pending_counts(db, business_date=business_date)
    return FnePendingCountOut(pending=pending, uncertain=uncertain, failed=failed)


@router.get(
    "/fne/daily-summary",
    response_model=FneDailySummaryOut,
    summary="Récapitulatif fiscal d'une journée",
)
def daily_summary(
    db: Session = Depends(get_db),
    _: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    business_date: Optional[date] = Query(None, description="Journée comptable"),
) -> FneDailySummaryOut:
    """Récapitulatif fiscal journalier."""
    if business_date is None:
        business_date = datetime.now(timezone.utc).date()
    return fne_service.daily_summary(db, business_date)


# Rétro-compatibilité pour l'ancien endpoint POST /api/v1/fne/generate
@router.post(
    "/fne/generate",
    status_code=status.HTTP_201_CREATED,
    deprecated=True,
    summary="Alias rétro-compatible pour émettre une FNE",
)
def legacy_generate(
    payload: FneGenerateRequest,
    request: Request,
    response: Response,
    idempotency_key: OptionalIdempotencyKey = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
    provider: Any = Depends(get_fne_provider),
) -> dict[str, Any]:
    from caisse.domain.fne import FneTemplate
    from caisse.models.customer import Customer

    request_hash = idempotency.hash_request(payload)
    if idempotency_key:
        replay = idempotency.find_replay(
            db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
        )
        if replay is not None:
            idempotency.apply_replay_headers(response)
            return replay

    if payload.template:
        template = payload.template
    elif payload.customer_id:
        cust = db.get(Customer, str(payload.customer_id))
        if cust and cust.ncc:
            template = FneTemplate.B2B
        elif cust and cust.tax_regime in ("B2G", "B2F", "B2C"):
            template = FneTemplate(cust.tax_regime)
        else:
            template = FneTemplate.B2C
    else:
        template = FneTemplate.B2C
    doc, submitted = fne_service.issue_for_order(
        db,
        payload.order_id,
        template=template,
        customer_id=payload.customer_id,
        provider=provider,
        user=user,
    )
    buyer_ncc = ""
    if doc.customer:
        buyer_ncc = doc.customer.ncc or ""
    res = {
        "id": str(doc.id),
        "order_id": str(doc.order_id),
        "customer_id": str(doc.customer_id) if doc.customer_id else None,
        "document_type": str(doc.type),
        "status": str(doc.status),
        "invoice_number": doc.external_number,
        "qr_url": doc.qr_payload,
        "fne_token": doc.qr_payload,
        "payload": {
            "buyer": {"ncc": buyer_ncc},
            "totals": {"total_ttc_xof": doc.fne_amount_ttc_xof or (doc.order.total_ttc_xof if doc.order else 0)},
            "raw": doc.payload,
        },
        "response_payload": doc.raw_response,
        "error_message": doc.last_error,
        "retry_count": doc.attempts,
        "submitted_at": doc.created_at,
        "certified_at": doc.certified_at,
        "created_at": doc.created_at,
        "updated_at": doc.created_at,
        "document": fne_service.to_out(db, doc).model_dump(mode="json"),
        "warnings": [w.model_dump(mode="json") for w in fne_service.warnings_for(db, doc)],
    }
    if idempotency_key:
        idempotency.save(
            db,
            idempotency_key,
            method="POST",
            path=request.url.path,
            request_hash=request_hash,
            status=201 if submitted else 200,
            body=res,
            user_id=user.id,
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
                return replay
            raise
    return res




@router.get("/fne/export", summary="Exporter les documents FNE en CSV")
def export_fne_csv(
    db: Session = Depends(get_db),
    _: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    status: Optional[str] = Query(None, description="Filtrer par statut"),
    start_date: Optional[datetime] = Query(None, description="Date début"),
) -> Response:
    docs = fne_repo.list_documents(db, status=status, start_date=start_date, limit=1000)
    lines = ["ID,Numero_Facture,Client,Type,Statut,Montant_TTC,Date_Creation"]
    for d in docs:
        client_name = d.customer.name if d.customer else ""
        lines.append(f"{d.id},{d.external_number or ''},{client_name},{d.type},{d.status},{d.fne_amount_ttc_xof or ''},{d.created_at}")
    csv_content = "\n".join(lines)

    filename = f"fne_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    return Response(
        content=csv_content,
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )

