"""Routes de l'agent d'impression du terminal (jeton de terminal, pas de PIN).

Boucle de l'agent : `POST /print-agent/poll` toutes les ~2 s ; s'il reçoit un travail, il
l'imprime, rend le résultat, puis interroge de nouveau sans attendre.
"""

import uuid
from typing import Annotated

from fastapi import APIRouter, Path, Response, status

from caisse.deps import Ctx, CurrentTerminal, DbSession
from caisse.domain.enums import PrintJobType
from caisse.schemas.printing import AgentJobOut, AgentPollIn, AgentPollOut, AgentResultIn
from caisse.services import printing_service
from caisse.services.audit_service import RequestContext

router = APIRouter(prefix="/print-agent", tags=["Agent d'impression"])

JobId = Annotated[uuid.UUID, Path(description="Identifiant du travail d'impression")]


@router.post("/poll", response_model=AgentPollOut, summary="Interrogation de l'agent")
def poll(body: AgentPollIn, terminal: CurrentTerminal, db: DbSession) -> AgentPollOut:
    """Signale l'agent (et l'état de l'imprimante) et lui confie le plus ancien travail en
    file, passé `PRINTING`. `job: null` : rien à imprimer, ou imprimante rapportée hors ligne.

    Erreurs : `401 TERMINAL_TOKEN_INVALID` (jeton inconnu ou révoqué)."""
    job = printing_service.claim_next(db, terminal, body.printer)
    if job is None:
        return AgentPollOut(job=None)
    return AgentPollOut(
        job=AgentJobOut(
            id=job.id,
            type=job.type,
            content=job.rendered or "",
            open_drawer=job.open_drawer,
            cut=job.type != PrintJobType.DRAWER,
            is_reprint=job.is_reprint,
        )
    )


@router.post(
    "/jobs/{job_id}/result",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
    summary="Résultat d'un travail",
)
def result(
    job_id: JobId, body: AgentResultIn, terminal: CurrentTerminal, db: DbSession, ctx: Ctx
) -> None:
    """Fige `DONE` ou `FAILED`. Renvoyer le même résultat est sans effet (réponse perdue).

    Erreurs : `401 TERMINAL_TOKEN_INVALID`, `404 NOT_FOUND`, `409 PRINT_JOB_NOT_CLAIMED`
    (travail pris par un autre terminal, ou remis en file entre-temps)."""
    printing_service.report_result(
        db,
        terminal,
        job_id,
        printed=body.printed,
        error=body.error,
        ctx=RequestContext(device_id=terminal.name, ip=ctx.ip),
    )
