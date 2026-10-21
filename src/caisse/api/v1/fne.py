import csv
import io
import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Path, Query, Response, status

from caisse.deps import Ctx, CurrentUser, DbSession, FneProviderDep, Paging, Responsable
from caisse.domain.enums import FneStatus
from caisse.pagination import split
from caisse.repositories import fne as fne_repo
from caisse.schemas.common import Page
from caisse.schemas.fne import (
    FneDailySummaryOut,
    FneDocumentOut,
    FneDocumentResult,
    FneIssueIn,
    FnePendingCountOut,
    FneRefundIn,
    FneResolveIn,
)
from caisse.security import utcnow
from caisse.services import auth_service, fne_service

router = APIRouter(tags=["FNE"])

OrderId = Annotated[uuid.UUID, Path(description="Identifiant de la commande")]
DocumentId = Annotated[uuid.UUID, Path(description="Identifiant du document FNE")]


@router.post(
    "/orders/{order_id}/fne",
    response_model=FneDocumentResult,
    status_code=status.HTTP_201_CREATED,
    summary="Émettre la FNE d'une commande soldée",
)
def issue(
    order_id: OrderId,
    body: FneIssueIn,
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    provider: FneProviderDep,
    response: Response,
) -> FneDocumentResult:
    """FNE **à la demande** (PLAN-FNE D1). Certification synchrone, au plus
    `FNE_SYNC_TIMEOUT_SECONDS` ; la réponse est toujours `201` (ou `200`, voir plus bas) et l'issue
    se lit dans `document.status` et `warnings` :

    - `CERTIFIED` : `external_number` et `qr_payload` (lien de vérification DGI, page A4) ;
    - `QUEUED` + `FNE_QUEUED` : FNE injoignable, renvoi prévu (`next_retry_at`) ;
    - `FAILED` + `FNE_REJECTED` : refusée par la DGI, corriger puis `retry` ;
    - `SUBMITTING` + `is_uncertain` + `FNE_UNCERTAIN` : issue inconnue, vérifier dans l'espace
      FNE puis `resolve` ;
    - `MANUAL` : `FNE_PROVIDER=manual`, à saisir dans l'application FNE.

    Si la commande a déjà une FNE (non refusée), elle est renvoyée **sans nouvel appel**, en `200` :
    un double clic ne certifie jamais deux fois.

    Erreurs : `404 NOT_FOUND` (commande, client), `409 FNE_ORDER_NOT_PAID`,
    `409 FNE_NOT_CONFIGURED` (`meta.missing_settings`), `422 FNE_CUSTOMER_REQUIRED` (hors B2C),
    `422 FNE_NCC_REQUIRED` (B2B sans NCC), `422 FNE_NO_PAYMENT`, `422 FNE_VAT_RATE_UNMAPPED`,
    `422 FNE_PAYMENT_METHOD_UNMAPPED`, `422 FNE_FIELD_REQUIRED` (client de passage non paramétré).
    """
    doc, submitted = fne_service.issue_for_order(
        db,
        order_id,
        template=body.template,
        customer_id=body.customer_id,
        payment_method=body.payment_method,
        provider=provider,
        user=user,
        ctx=ctx,
    )
    if not submitted:
        response.status_code = status.HTTP_200_OK
    return FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )


@router.get("/orders/{order_id}/fne", response_model=FneDocumentOut, summary="FNE d'une commande")
def get_for_order(order_id: OrderId, _: CurrentUser, db: DbSession) -> FneDocumentOut:
    """FNE de vente de la commande. Erreurs : `404 NOT_FOUND` (aucune FNE émise)."""
    return fne_service.to_out(db, fne_service.get_for_order(db, order_id))


@router.get("/fne/documents", response_model=Page[FneDocumentOut], summary="Documents FNE (suivi)")
def list_documents(
    _: Responsable,
    db: DbSession,
    page: Paging,
    status_filter: Annotated[
        FneStatus | None, Query(alias="status", description="Filtrer sur un statut")
    ] = None,
    business_date: Annotated[
        date | None, Query(description="Journée comptable de la commande")
    ] = None,
) -> Page[FneDocumentOut]:
    """Les plus récents en premier, par pages de `limit` : `next_cursor` donne la suivante."""
    rows = fne_repo.list_documents(db, status=status_filter, business_date=business_date, page=page)
    docs, next_cursor = split(rows, page, lambda d: (d.created_at, d.id))
    return Page(items=fne_service.to_out_many(db, docs), next_cursor=next_cursor)


EXPORT_COLUMNS = [
    "cree_le",
    "journee",
    "commande",
    "type",
    "statut",
    "incertain",
    "numero_fne",
    "client",
    "ncc",
    "montant_ttc_xof",
    "certifie_le",
    "derniere_erreur",
]


@router.get(
    "/fne/documents/export",
    response_class=Response,
    summary="Exporter les documents FNE (CSV)",
    responses={200: {"content": {"text/csv": {}}, "description": "Fichier CSV"}},
)
def export_documents(
    _: Responsable,
    db: DbSession,
    status_filter: Annotated[
        FneStatus | None, Query(alias="status", description="Filtrer sur un statut")
    ] = None,
    date_from: Annotated[date | None, Query(description="Journée de début (incluse)")] = None,
    date_to: Annotated[date | None, Query(description="Journée de fin (incluse)")] = None,
) -> Response:
    """CSV pour Excel (séparateur `;`, UTF-8 avec BOM), un document par ligne, du plus ancien
    au plus récent ; journées = journées comptables des commandes. Réservé au RESPONSABLE."""
    buffer = io.StringIO()
    writer = csv.writer(buffer, delimiter=";", lineterminator="\r\n")
    writer.writerow(EXPORT_COLUMNS)
    for doc, order, customer in fne_repo.export_rows(
        db, status=status_filter, date_from=date_from, date_to=date_to
    ):
        writer.writerow(
            [
                doc.created_at.isoformat(timespec="seconds"),
                order.business_date.isoformat() if order else "",
                order.order_number if order else "",
                doc.type,
                doc.status,
                "oui" if doc.is_uncertain else "non",
                doc.external_number or "",
                customer.company_name if customer else "",
                customer.ncc or "" if customer else "",
                doc.fne_amount_ttc_xof if doc.fne_amount_ttc_xof is not None else "",
                doc.certified_at.isoformat(timespec="seconds") if doc.certified_at else "",
                (doc.last_error or "").replace("\n", " ")[:200],
            ]
        )
    stamp = (date_to or date_from or utcnow().date()).isoformat()
    return Response(
        content="\ufeff" + buffer.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="fne-{stamp}.csv"'},
    )


@router.post(
    "/fne/documents/{document_id}/retry",
    response_model=FneDocumentResult,
    summary="Renvoyer un document FNE",
)
def retry(
    document_id: DocumentId,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    provider: FneProviderDep,
) -> FneDocumentResult:
    """Documents `QUEUED`, `FAILED` (reconstruit à partir de la commande et du client
    éventuellement corrigé) ou `PENDING`.

    Erreurs : `404 NOT_FOUND`, `409 FNE_DOCUMENT_STATE` (`meta.reason` : `uncertain` →
    passer par `resolve` ; `not_retryable` → déjà certifié, manuel ou en cours), plus les erreurs
    `422 FNE_*` de l'émission.
    """
    doc = fne_service.retry(db, document_id, provider=provider, user=user, ctx=ctx)
    return FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )


@router.post(
    "/fne/documents/{document_id}/resolve",
    response_model=FneDocumentResult,
    summary="Trancher un document FNE incertain",
)
def resolve(
    document_id: DocumentId,
    body: FneResolveIn,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    provider: FneProviderDep,
) -> FneDocumentResult:
    """Après vérification dans l'espace FNE (« Reçus et factures émis ») : facture numérotée →
    `is_certified: true` avec le n° relevé ; absente ou sans n° → `is_certified: false`, le
    document est renvoyé.

    Erreurs : `404 NOT_FOUND`, `409 FNE_DOCUMENT_STATE` (`meta.reason = "not_uncertain"`),
    `422 VALIDATION_ERROR` (n° manquant).
    """
    doc = fne_service.resolve(
        db,
        document_id,
        is_certified=body.is_certified,
        external_number=body.external_number,
        qr_payload=body.qr_payload,
        provider=provider,
        user=user,
        ctx=ctx,
    )
    return FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )


@router.post(
    "/fne/documents/{document_id}/refund",
    response_model=FneDocumentResult,
    status_code=status.HTTP_201_CREATED,
    summary="Émettre un avoir FNE",
)
def refund(
    document_id: DocumentId,
    body: FneRefundIn,
    user: Responsable,
    db: DbSession,
    ctx: Ctx,
    provider: FneProviderDep,
) -> FneDocumentResult:
    """Avoir total ou partiel sur une FNE de vente certifiée par l'API. Renvoie le document
    d'avoir (`type: REFUND`, `parent_document_id`) ; mêmes statuts que l'émission.

    Erreurs : `404 NOT_FOUND` (document, ligne non certifiée), `409 FNE_DOCUMENT_STATE`
    (`meta.reason = "not_refundable"` : non certifiée, manuelle, ou certifiée hors API),
    `422 FNE_REFUND_EXCEEDS` (`meta.available`).
    """
    doc = fne_service.refund(
        db,
        document_id,
        lines=[(line.order_item_id, line.quantity) for line in body.items],
        provider=provider,
        user=user,
        ctx=ctx,
    )
    return FneDocumentResult(
        document=fne_service.to_out(db, doc), warnings=fne_service.warnings_for(db, doc)
    )


@router.get(
    "/fne/documents/{document_id}/duplicate",
    response_model=FneDocumentOut,
    summary="Duplicata d'une FNE certifiée",
)
def duplicate(document_id: DocumentId, _: CurrentUser, db: DbSession) -> FneDocumentOut:
    """Pour réimprimer : `qr_payload` est le lien de la page A4 de vérification DGI.

    Erreurs : `404 NOT_FOUND`, `409 FNE_DOCUMENT_STATE` (`meta.reason = "not_certified"`).
    """
    return fne_service.to_out(db, fne_service.get_duplicate(db, document_id))


@router.get(
    "/fne/pending-count", response_model=FnePendingCountOut, summary="Compteur de la barre d'état"
)
def pending_count(_: CurrentUser, db: DbSession) -> FnePendingCountOut:
    """Documents en attente d'une action (PENDING, QUEUED, SUBMITTING, FAILED)."""
    pending, uncertain, failed = fne_repo.pending_counts(db)
    return FnePendingCountOut(pending=pending, uncertain=uncertain, failed=failed)


@router.get(
    "/fne/daily-summary",
    response_model=FneDailySummaryOut,
    summary="Récapitulatif fiscal d'une journée",
)
def daily_summary(
    _: Responsable,
    db: DbSession,
    business_date: Annotated[
        date | None,
        Query(
            description="Journée comptable ; défaut : celle de la session ouverte, sinon le jour"
        ),
    ] = None,
) -> FneDailySummaryOut:
    """Ventes soldées par groupe fiscal et part couverte par une FNE certifiée (contrôle interne,
    rapprochement avec l'espace FNE)."""
    if business_date is None:
        session = auth_service.current_open_session(db)
        business_date = session.business_date if session else utcnow().date()
    return fne_service.daily_summary(db, business_date)
