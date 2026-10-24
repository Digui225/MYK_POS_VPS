from typing import Any

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.database import get_db
from caisse.deps import (
    DbSession,
    Paging,
    Responsable,
    get_current_user,
    require_device_id,
    require_role,
)
from caisse.idempotency import IdempotencyKey
from caisse.models.user import User
from caisse.pagination import split
from caisse.schemas.common import Page
from caisse.schemas.sessions import (
    CashMovementRequest,
    CashMovementResponse,
    CashSessionResponse,
    SessionCloseRequest,
    SessionOpenRequest,
    XReportResponse,
    ZReportResponse,
)
from caisse.services.cash_session_service import CashSessionService

router = APIRouter(prefix="/cash-sessions", tags=["Sessions de caisse"])


@router.get("", response_model=Page[CashSessionResponse], summary="Historique des sessions de caisse")
def list_sessions_history(
    user: Responsable,
    db: DbSession,
    page: Paging,
) -> Page[CashSessionResponse]:
    """Sessions clôturées, les plus récentes en premier, par pages de `limit` : `next_cursor` donne la suivante."""
    session_service = CashSessionService(db)
    rows = session_service.list_history(page=page)
    sessions, next_cursor = split(rows, page, lambda s: (s.closed_at or s.opened_at, s.id))
    return Page(
        items=[session_service._to_session_response(s) for s in sessions],
        next_cursor=next_cursor,
    )


@router.get("/current", response_model=CashSessionResponse, summary="Session de caisse active sur ce poste")
async def get_current_session(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CashSessionResponse:
    session_service = CashSessionService(db)
    return session_service.get_current_session()


@router.post(
    "",
    response_model=CashSessionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Ouvrir une session de caisse (idempotent)",
)
async def open_session(
    payload: SessionOpenRequest,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> CashSessionResponse:
    session_service = CashSessionService(db)
    result, replayed = session_service.open_session(
        cash_register_id=payload.cash_register_id,
        opening_float_xof=payload.opening_float_xof,
        business_date_str=payload.business_date,
        user_id=current_user.id,
        device_id=device_id,
        idempotency_key=idempotency_key,
        path=request.url.path,
        payload=payload,
    )
    if replayed:
        idempotency.apply_replay_headers(response)
    return result


@router.get("/{id}/x-report", response_model=XReportResponse, summary="Consulter le Rapport X (intermédiaire)")
async def get_x_report(
    id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> XReportResponse:
    session_service = CashSessionService(db)
    return session_service.get_x_report(id)


@router.post(
    "/{id}/close",
    response_model=CashSessionResponse,
    summary="Clôturer la session et générer le Rapport Z",
)
async def close_session(
    id: str,
    payload: SessionCloseRequest,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
    current_user: User = Depends(require_role("CAISSIER")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> CashSessionResponse:
    session_service = CashSessionService(db)
    result, replayed = session_service.close_session(
        session_id=id,
        counted_breakdown=payload.counted_breakdown,
        user_id=current_user.id,
        notes=payload.notes,
        device_id=device_id,
        idempotency_key=idempotency_key,
        path=request.url.path,
        payload=payload,
    )
    if replayed:
        idempotency.apply_replay_headers(response)
    return result


@router.get(
    "/{id}/z-report",
    response_model=ZReportResponse,
    summary="Consulter le Rapport Z définitif figé",
)
async def get_z_report(
    id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ZReportResponse:
    session_service = CashSessionService(db)
    return session_service.get_z_report(id)


@router.post(
    "/{id}/print-z",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Imprimer le ticket de Rapport Z fiscal",
)
async def print_z_report_from_session(
    id: str,
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    from caisse.services.printing_service import PrintingService
    service = PrintingService(db)
    job = service.print_z_report(
        session_id=id,
        cashier_name=current_user.full_name,
        user_id=current_user.id,
        device_id=device_id,
    )
    return {
        "message": "Job d'impression du Rapport Z créé",
        "print_job_id": job.id,
        "session_id": id,
    }



@router.post(
    "/{id}/movements",
    response_model=CashMovementResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Entrée / Sortie de tiroir",
)
async def create_cash_movement(
    id: str,
    payload: CashMovementRequest,
    current_user: User = Depends(require_role("CAISSIER")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> CashMovementResponse:
    session_service = CashSessionService(db)
    return session_service.add_movement(
        session_id=id,
        movement_type=payload.type,
        amount_xof=payload.amount_xof,
        reason=payload.reason,
        user_id=current_user.id,
        device_id=device_id,
    )
