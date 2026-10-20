import uuid
from typing import Annotated

from fastapi import APIRouter, Path, Query, status

from caisse.deps import Admin, Ctx, CurrentUser, DbSession, Responsable
from caisse.domain.enums import PrintJobStatus
from caisse.schemas.common import Page
from caisse.schemas.printing import (
    PrintingStatusOut,
    PrintJobOut,
    PrintTerminalCreate,
    PrintTerminalCreated,
    PrintTerminalOut,
)
from caisse.services import print_terminal_service, printing_service

router = APIRouter(prefix="/printing", tags=["Impression"])

JobId = Annotated[uuid.UUID, Path(description="Identifiant du travail d'impression")]
TerminalId = Annotated[uuid.UUID, Path(description="Identifiant du terminal d'impression")]


@router.get("/status", response_model=PrintingStatusOut, summary="État de l'impression")
def status_(_: CurrentUser, db: DbSession) -> PrintingStatusOut:
    """Agent, imprimante et file. N'échoue jamais : `agent_online: false` si aucun agent ne
    s'est signalé depuis 15 s ; l'état de l'imprimante est celui que l'agent rapporte."""
    return printing_service.status(db)


@router.post(
    "/open-drawer",
    response_model=PrintJobOut,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Ouverture manuelle du tiroir",
)
def open_drawer(user: Responsable, db: DbSession, ctx: Ctx) -> PrintJobOut:
    """Action tracée, hors vente (ex. correction de caisse). Mise en file (`DRAWER`) : le tiroir
    s'ouvre quand l'agent la prend, en général sous 2 s.

    Erreurs : `503 PRINT_AGENT_UNAVAILABLE` (aucun agent en ligne), `503 PRINTER_UNAVAILABLE`
    (l'agent rapporte l'imprimante hors ligne)."""
    job = printing_service.request_open_drawer(db, user_id=user.id, ctx=ctx)
    return PrintJobOut.model_validate(job)


@router.get("/jobs", response_model=Page[PrintJobOut], summary="File d'impression")
def jobs(
    _: CurrentUser,
    db: DbSession,
    status_filter: Annotated[PrintJobStatus | None, Query(alias="status")] = None,
) -> Page[PrintJobOut]:
    items = printing_service.list_jobs(db, status=status_filter)
    return Page(items=[PrintJobOut.model_validate(job) for job in items])


@router.get("/jobs/{job_id}", response_model=PrintJobOut, summary="Travail d'impression")
def job(job_id: JobId, _: CurrentUser, db: DbSession) -> PrintJobOut:
    """Suivi d'un ticket après un paiement ou une clôture : `QUEUED` → `PRINTING` → `DONE`
    ou `FAILED`. Erreurs : `404 NOT_FOUND`."""
    return PrintJobOut.model_validate(printing_service.get_job(db, job_id))


@router.post(
    "/jobs/{job_id}/retry",
    response_model=PrintJobOut,
    summary="Rejeu d'un travail d'impression",
)
def retry(job_id: JobId, user: CurrentUser, db: DbSession, ctx: Ctx) -> PrintJobOut:
    """Remet en file un travail `FAILED`, ou `PRINTING` depuis plus de 2 min (agent arrêté en
    cours d'impression).

    Erreurs : `404 NOT_FOUND`, `409 PRINT_JOB_NOT_RETRYABLE` (déjà `DONE`, déjà en file, ou pris
    à l'instant)."""
    job = printing_service.retry(db, job_id, user_id=user.id, ctx=ctx)
    return PrintJobOut.model_validate(job)


@router.post(
    "/test",
    response_model=PrintJobOut,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Ticket de test",
)
def test_print(user: Admin, db: DbSession, ctx: Ctx) -> PrintJobOut:
    """Erreurs : `503 PRINT_AGENT_UNAVAILABLE`, `503 PRINTER_UNAVAILABLE`."""
    job = printing_service.request_test_print(db, user_id=user.id, ctx=ctx)
    return PrintJobOut.model_validate(job)


@router.get("/terminals", response_model=Page[PrintTerminalOut], summary="Terminaux d'impression")
def terminals(_: Admin, db: DbSession) -> Page[PrintTerminalOut]:
    items = print_terminal_service.list_terminals(db)
    return Page(items=[PrintTerminalOut.model_validate(t) for t in items])


@router.post(
    "/terminals",
    response_model=PrintTerminalCreated,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un terminal d'impression",
)
def create_terminal(
    body: PrintTerminalCreate, user: Admin, db: DbSession, ctx: Ctx
) -> PrintTerminalCreated:
    """Le jeton n'est renvoyé qu'ici : le copier dans la configuration de l'agent du poste.

    Erreurs : `409 PRINT_TERMINAL_NAME_EXISTS`."""
    terminal, token = print_terminal_service.create_terminal(
        db, name=body.name, actor_id=user.id, ctx=ctx
    )
    return PrintTerminalCreated(terminal=PrintTerminalOut.model_validate(terminal), token=token)


@router.post(
    "/terminals/{terminal_id}/revoke",
    response_model=PrintTerminalOut,
    summary="Révoquer un terminal d'impression",
)
def revoke_terminal(
    terminal_id: TerminalId, user: Admin, db: DbSession, ctx: Ctx
) -> PrintTerminalOut:
    """Son agent est refusé dès sa prochaine interrogation. Sans effet si déjà révoqué.

    Erreurs : `404 NOT_FOUND`."""
    terminal = print_terminal_service.revoke_terminal(db, terminal_id, actor_id=user.id, ctx=ctx)
    return PrintTerminalOut.model_validate(terminal)
