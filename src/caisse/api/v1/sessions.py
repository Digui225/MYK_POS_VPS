import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Path, Request, Response, status

from caisse import idempotency
from caisse.deps import Ctx, CurrentUser, DbSession, Paging, Responsable
from caisse.errors import NoOpenSessionError
from caisse.idempotency import IdempotencyKey
from caisse.models.cash_session import CashSession
from caisse.pagination import split
from caisse.repositories import sessions as sessions_repo
from caisse.schemas.common import Page
from caisse.schemas.printing import PrintJobOut
from caisse.schemas.sessions import (
    CashSessionOut,
    CloseSessionIn,
    MovementIn,
    MovementOut,
    MovementResult,
    OpenSessionIn,
    XReportOut,
    ZReportOut,
)
from caisse.services import auth_service, cash_session_service

router = APIRouter(prefix="/cash-sessions", tags=["Sessions de caisse"])

SessionId = Annotated[uuid.UUID, Path(description="Identifiant de la session de caisse")]


@router.get("/current", response_model=CashSessionOut, summary="Session ouverte sur ce poste")
def current(_: CurrentUser, db: DbSession) -> CashSessionOut:
    """MVP mono-poste : la session non clôturée la plus récente, toutes caisses confondues.

    Erreurs : `409 NO_OPEN_SESSION`.
    """
    session = auth_service.current_open_session(db)
    if session is None:
        raise NoOpenSessionError()
    return CashSessionOut.model_validate(session)


@router.post(
    "",
    response_model=CashSessionOut,
    status_code=status.HTTP_201_CREATED,
    summary="Ouvrir une session de caisse",
)
def open_session(
    body: OpenSessionIn,
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> CashSessionOut:
    """Idempotent (`Idempotency-Key` obligatoire).

    Erreurs : `404 NOT_FOUND` (caisse inconnue ou hors service : `GET /cash-registers`),
    `409 SESSION_ALREADY_OPEN`, `409 BUSINESS_DATE_MISMATCH`
    (`meta.existing_session_id` ; rejouer avec `confirm_business_date: true`),
    `409 IDEMPOTENCY_CONFLICT`.
    """
    request_hash = idempotency.hash_request(body)
    replay = idempotency.find_replay(
        db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
    )
    if replay is not None:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replay"] = "true"
        return CashSessionOut.model_validate(replay)

    session = cash_session_service.open_session(
        db,
        cash_register_id=body.cash_register_id,
        opening_float_xof=body.opening_float_xof,
        business_date=body.business_date,
        confirm_business_date=body.confirm_business_date,
        actor_id=user.id,
        ctx=ctx,
    )
    out = CashSessionOut.model_validate(session)
    idempotency.save(
        db,
        idempotency_key,
        method="POST",
        path=request.url.path,
        request_hash=request_hash,
        status=status.HTTP_201_CREATED,
        body=out.model_dump(mode="json"),
        user_id=user.id,
    )
    db.commit()
    return out


@router.get(
    "/{session_id}/x-report", response_model=XReportOut, summary="Rapport X (lecture seule)"
)
def x_report(session_id: SessionId, _: CurrentUser, db: DbSession) -> XReportOut:
    """Agrégats de la session en cours, sans effet de bord. Erreurs : `404 NOT_FOUND`."""
    return cash_session_service.x_report(db, session_id)


@router.post(
    "/{session_id}/close",
    response_model=ZReportOut,
    status_code=status.HTTP_201_CREATED,
    summary="Clôturer la session (Z)",
)
def close_session(
    session_id: SessionId,
    body: CloseSessionIn,
    user: CurrentUser,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> ZReportOut:
    """Idempotent (`Idempotency-Key` obligatoire).

    Erreurs : `404 NOT_FOUND`, `409 SESSION_ALREADY_CLOSED`,
    `409 SESSION_HAS_OPEN_ORDERS` (`meta.open_orders[]`), `409 IDEMPOTENCY_CONFLICT`.
    """
    request_hash = idempotency.hash_request(body)
    replay = idempotency.find_replay(
        db, idempotency_key, method="POST", path=request.url.path, request_hash=request_hash
    )
    if replay is not None:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replay"] = "true"
        return ZReportOut.model_validate(replay)

    cash_session_service.close_session(
        db,
        session_id,
        counted_breakdown=body.counted_breakdown,
        notes=body.notes,
        actor_id=user.id,
        ctx=ctx,
    )
    out = cash_session_service.z_report(db, session_id)
    idempotency.save(
        db,
        idempotency_key,
        method="POST",
        path=request.url.path,
        request_hash=request_hash,
        status=status.HTTP_201_CREATED,
        body=out.model_dump(mode="json"),
        user_id=user.id,
    )
    db.commit()
    return out


@router.get("/{session_id}/z-report", response_model=ZReportOut, summary="Rapport Z figé")
def z_report(session_id: SessionId, _: CurrentUser, db: DbSession) -> ZReportOut:
    """Erreurs : `404 NOT_FOUND`, `409 SESSION_NOT_CLOSED`."""
    return cash_session_service.z_report(db, session_id)


@router.post(
    "/{session_id}/z-report/reprint",
    response_model=PrintJobOut,
    summary="Ré-imprimer le ticket Z",
)
def reprint_z(session_id: SessionId, user: CurrentUser, db: DbSession, ctx: Ctx) -> PrintJobOut:
    """Duplicata du ticket Z tel qu'imprimé à la clôture (jamais recalculé), marqué
    `is_reprint: true` ; n'ouvre pas le tiroir. Le travail part `QUEUED` : l'agent du terminal
    le prend ; suivre `GET /printing/jobs/{id}`, rejouer un échec par `/printing/jobs/{id}/retry`.

    Erreurs : `404 NOT_FOUND`, `409 SESSION_NOT_CLOSED`, `409 NO_RECEIPT_TO_REPRINT`
    (session clôturée sans ticket Z enregistré).
    """
    job = cash_session_service.reprint_z(db, session_id, user_id=user.id, ctx=ctx)
    return PrintJobOut.model_validate(job)


@router.get("", response_model=Page[CashSessionOut], summary="Historique des sessions")
def history(_: Responsable, db: DbSession, page: Paging) -> Page[CashSessionOut]:
    """Sessions clôturées, les plus récentes en premier, par pages de `limit` : `next_cursor`
    donne la suivante. Réservé au RESPONSABLE."""
    rows = sessions_repo.list_history(db, page=page)
    sessions, next_cursor = split(rows, page, _closed_key)
    return Page(items=[CashSessionOut.model_validate(s) for s in sessions], next_cursor=next_cursor)


def _closed_key(session: CashSession) -> tuple[datetime, uuid.UUID]:
    assert session.closed_at is not None  # sessions clôturées uniquement
    return session.closed_at, session.id


@router.post(
    "/{session_id}/movements",
    response_model=MovementResult,
    status_code=status.HTTP_201_CREATED,
    summary="Entrée ou sortie de tiroir",
)
def add_movement(
    session_id: SessionId, body: MovementIn, user: CurrentUser, db: DbSession, ctx: Ctx
) -> MovementResult:
    """Erreurs : `404 NOT_FOUND`, `409 NO_OPEN_SESSION` (session déjà clôturée)."""
    movement = cash_session_service.add_movement(
        db,
        session_id,
        type=body.type,
        amount_xof=body.amount_xof,
        reason=body.reason,
        actor_id=user.id,
        ctx=ctx,
    )
    session = sessions_repo.get(db, session_id)
    assert session is not None
    return MovementResult(
        movement=MovementOut.model_validate(movement),
        session=CashSessionOut.model_validate(session),
    )
