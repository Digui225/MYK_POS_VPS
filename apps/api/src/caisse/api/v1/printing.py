from typing import Annotated, Any
from fastapi import APIRouter, Depends, Path, Query, Response, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import Admin, CurrentUser, DbSession, Responsable, Ctx, Paging, require_role, require_device_id
from caisse.models.user import User
from caisse.models.order import Order
from caisse.errors import CaisseException
from caisse.pagination import split
from caisse.schemas.common import Page
from caisse.schemas.printing import (
    PrintingStatusOut,
    PrintJobOut,
    PrintTerminalCreate,
    PrintTerminalCreated,
    PrintTerminalOut,
)
from caisse.services.printing_service import PrintingService
from caisse.services.print_terminal_service import PrintTerminalService

router = APIRouter(prefix="/printing", tags=["Impression & Tiroir"])


@router.get("/status", response_model=PrintingStatusOut, summary="État de l'imprimante et de l'agent d'impression")
def get_printer_status(db: DbSession, current_user: CurrentUser) -> PrintingStatusOut:
    service = PrintingService(db)
    return service.get_status()


@router.get("/jobs", response_model=Page[PrintJobOut], summary="Lister les travaux d'impression")
def list_print_jobs(
    db: DbSession,
    current_user: CurrentUser,
    page: Paging,
    status_filter: Annotated[str | None, Query(alias="status", description="Filtrer par statut")] = None,
) -> Page[PrintJobOut]:
    service = PrintingService(db)
    rows = service.repo.list_jobs(status=status_filter, page=page)
    items, next_cursor = split(rows, page, lambda job: (job.created_at, job.id))
    return Page(items=[PrintJobOut.model_validate(j) for j in items], next_cursor=next_cursor)


@router.get("/jobs/{job_id}", response_model=PrintJobOut, summary="Détail d'un travail d'impression")
def get_print_job(
    job_id: Annotated[str, Path(description="Identifiant du travail")],
    db: DbSession,
    current_user: CurrentUser,
) -> PrintJobOut:
    service = PrintingService(db)
    job = service.repo.get(job_id)
    if not job:
        raise CaisseException(
            code="PRINT_JOB_NOT_FOUND",
            title="Travail introuvable",
            detail=f"Travail d'impression {job_id} introuvable.",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    return PrintJobOut.model_validate(job)


@router.post("/jobs/{job_id}/retry", response_model=PrintJobOut, summary="Remettre un travail en file d'attente")
def retry_print_job(
    job_id: Annotated[str, Path(description="Identifiant du travail")],
    db: DbSession,
    current_user: Responsable,
    ctx: Ctx,
) -> PrintJobOut:
    service = PrintingService(db)
    job = service.retry_job(job_id, user_id=current_user.id, device_id=ctx.device_id)
    return PrintJobOut.model_validate(job)


# --- Terminaux d'impression (ADMIN) ---


@router.get("/terminals", response_model=list[PrintTerminalOut], summary="Lister les postes d'impression")
def list_terminals(db: DbSession, current_user: Admin) -> list[PrintTerminalOut]:
    service = PrintTerminalService(db)
    return [PrintTerminalOut.model_validate(t) for t in service.list_terminals()]


@router.post(
    "/terminals",
    response_model=PrintTerminalCreated,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un terminal d'impression (jeton de l'agent)",
)
def create_terminal(
    body: PrintTerminalCreate,
    db: DbSession,
    current_user: Admin,
    ctx: Ctx,
) -> PrintTerminalCreated:
    """Crée un terminal et génère le jeton Bearer `pt_...` de l'agent.
    Ce jeton n'est renvoyé qu'une seule fois dans cette réponse."""
    service = PrintTerminalService(db)
    terminal, token = service.create_terminal(
        name=body.name, user_id=current_user.id, device_id=ctx.device_id
    )
    return PrintTerminalCreated(
        terminal=PrintTerminalOut.model_validate(terminal),
        token=token,
    )


@router.post(
    "/terminals/{terminal_id}/revoke",
    response_model=PrintTerminalOut,
    summary="Révoquer un terminal d'impression",
)
def revoke_terminal(
    terminal_id: Annotated[str, Path(description="Identifiant du terminal")],
    db: DbSession,
    current_user: Admin,
    ctx: Ctx,
) -> PrintTerminalOut:
    service = PrintTerminalService(db)
    terminal = service.revoke_terminal(terminal_id, user_id=current_user.id, device_id=ctx.device_id)
    return PrintTerminalOut.model_validate(terminal)


# --- Actions directes d'impression & tiroir ---


@router.post("/reprint/{order_id}", status_code=status.HTTP_202_ACCEPTED, summary="Ré-imprimer un duplicata de ticket (tracé)")
def reprint_ticket(
    order_id: str,
    db: DbSession,
    current_user: CurrentUser,
    ctx: Ctx,
) -> dict[str, Any]:
    service = PrintingService(db)
    if order_id.startswith("Z-"):
        session_id = order_id[2:]
        job = service.print_z_report(
            session_id=session_id,
            cashier_name=current_user.full_name,
            user_id=current_user.id,
            device_id=ctx.device_id,
        )
        return {
            "message": "Job d'impression du Rapport Z créé",
            "print_job_id": job.id,
            "is_reprint": False,
            "session_id": session_id,
        }

    order = db.query(Order).filter(Order.id == order_id).first()
    if not order:
        raise CaisseException(
            code="ORDER_NOT_FOUND",
            title="Commande introuvable",
            detail=f"Aucune commande trouvée avec l'ID {order_id}.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    job = service.reprint_ticket(
        order=order,
        cashier_name=current_user.full_name,
        user_id=current_user.id,
        device_id=ctx.device_id,
    )

    return {
        "message": "Job d'impression de duplicata créé",
        "print_job_id": job.id,
        "is_reprint": True,
        "order_id": order_id,
    }


@router.post("/z-report/{session_id}", status_code=status.HTTP_202_ACCEPTED, summary="Imprimer le ticket de Rapport Z fiscal")
def print_z_report_endpoint(
    session_id: str,
    db: DbSession,
    current_user: CurrentUser,
    ctx: Ctx,
) -> dict[str, Any]:
    service = PrintingService(db)
    job = service.print_z_report(
        session_id=session_id,
        cashier_name=current_user.full_name,
        user_id=current_user.id,
        device_id=ctx.device_id,
    )
    return {
        "message": "Job d'impression du Rapport Z créé",
        "print_job_id": job.id,
        "session_id": session_id,
    }


@router.post("/open-drawer", status_code=status.HTTP_202_ACCEPTED, summary="Ouvrir le tiroir-caisse manuellement (rôle responsable)")
def open_drawer_manually(
    db: DbSession,
    current_user: Responsable,
    ctx: Ctx,
) -> dict[str, Any]:
    service = PrintingService(db)
    job = service.manual_open_drawer(user_id=current_user.id, device_id=ctx.device_id)
    return {
        "message": "Travail d'ouverture tiroir mis en file",
        "print_job_id": job.id,
    }


@router.post("/test-ticket", status_code=status.HTTP_202_ACCEPTED, summary="Imprimer un ticket de test")
@router.post("/test", status_code=status.HTTP_202_ACCEPTED, summary="Imprimer un ticket de test (alias contrat)")
def print_test_ticket(
    db: DbSession,
    current_user: Responsable,
    ctx: Ctx,
) -> dict[str, Any]:
    service = PrintingService(db)
    job = service.print_test_ticket(
        user_id=current_user.id,
        device_id=ctx.device_id,
    )
    return {
        "message": "Ticket de test mis en file",
        "print_job_id": job.id,
    }
