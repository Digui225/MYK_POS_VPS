"""Routes de l'agent d'impression du terminal (authentifié par jeton de terminal).

Boucle de l'agent : `POST /print-agent/poll` toutes les ~2 s ; s'il reçoit un travail, il
l'imprime, rend le résultat, puis interroge de nouveau sans attendre.
"""

from typing import Annotated

from fastapi import APIRouter, Path, Response, status

from caisse.deps import Ctx, CurrentTerminal, DbSession
from caisse.schemas.printing import AgentJobOut, AgentPollIn, AgentPollOut, AgentResultIn
from caisse.services.printing_service import PrintingService

router = APIRouter(prefix="/print-agent", tags=["Agent d'impression"])

JobId = Annotated[str, Path(description="Identifiant du travail d'impression")]


@router.post("/poll", response_model=AgentPollOut, summary="Interrogation de l'agent")
def poll(body: AgentPollIn, terminal: CurrentTerminal, db: DbSession) -> AgentPollOut:
    """Signale l'agent (et l'état de l'imprimante) et lui confie le plus ancien travail en
    file, passé PRINTING. `job: null` : rien à imprimer, ou imprimante rapportée hors ligne.

    Erreurs : `401 TERMINAL_TOKEN_INVALID` (jeton inconnu ou révoqué)."""
    service = PrintingService(db)
    job = service.claim_next(terminal, body.printer)
    if job is None:
        return AgentPollOut(job=None)

    return AgentPollOut(
        job=AgentJobOut(
            id=job.id,
            type=job.job_type,
            content=job.content or "",
            open_drawer=job.open_drawer,
            cut=job.cut,
            is_reprint=job.is_duplicate,
        )
    )


@router.post(
    "/jobs/{job_id}/result",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
    summary="Résultat d'un travail d'impression",
)
def report_job_result(
    job_id: JobId,
    body: AgentResultIn,
    terminal: CurrentTerminal,
    db: DbSession,
    ctx: Ctx,
) -> None:
    """Fige le travail en DONE ou FAILED. Renvoyer le même résultat est sans effet (idempotent).

    Erreurs : `401 TERMINAL_TOKEN_INVALID`, `404 PRINT_JOB_NOT_FOUND`, `409 PRINT_JOB_NOT_CLAIMED`
    (travail assigné à un autre terminal)."""
    service = PrintingService(db)
    service.report_result(
        terminal=terminal,
        job_id=job_id,
        printed=body.printed,
        error=body.error,
        device_id=ctx.device_id,
    )
