"""File d'impression (ticket, Z, tiroir, test), tirée par l'agent du terminal.

L'API tourne sur le VPS et ne peut pas joindre le restaurant : elle met les travaux en file
(`enqueue`), l'agent du terminal les prend un à un (`claim_next`) puis rend le résultat
(`report_result`). Une vente ou une clôture n'attend donc jamais l'imprimante : le travail part
`QUEUED` et le front suit son état par `GET /printing/jobs/{id}`.

Les actions directes (`request_open_drawer`, `request_test_print`) refusent quand aucun agent
ne s'est signalé récemment : demandées par un responsable/admin, elles doivent échouer tout de
suite plutôt que partir des minutes plus tard.
"""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.domain import receipt as receipt_domain
from caisse.domain.enums import PrintJobStatus, PrintJobType
from caisse.errors import (
    NotFoundError,
    PrintAgentUnavailableError,
    PrinterUnavailableError,
    PrintJobNotClaimedError,
    PrintJobNotRetryableError,
)
from caisse.models.print_job import PrintJob
from caisse.models.print_terminal import PrintTerminal
from caisse.pagination import PageRequest
from caisse.repositories import print_jobs as print_jobs_repo
from caisse.repositories import print_terminals as terminals_repo
from caisse.schemas.printing import PrinterReport, PrintingStatusOut
from caisse.services import audit_service
from caisse.services.audit_service import RequestContext


def _now() -> datetime:
    return datetime.now(UTC)


def enqueue(
    db: Session,
    *,
    job_type: PrintJobType,
    rendered: str,
    open_drawer: bool,
    order_id: uuid.UUID | None = None,
    session_id: uuid.UUID | None = None,
    payload: dict[str, Any] | None = None,
    is_reprint: bool = False,
    user_id: uuid.UUID,
) -> PrintJob:
    """Ajoute le travail à la transaction en cours, sans committer : le ticket part avec le
    paiement ou la clôture, ou pas du tout."""
    job = PrintJob(
        type=job_type,
        order_id=order_id,
        session_id=session_id,
        payload=payload or {},
        rendered=rendered,
        open_drawer=open_drawer,
        status=PrintJobStatus.QUEUED,
        is_reprint=is_reprint,
        requested_by=user_id,
    )
    db.add(job)
    db.flush()
    return job


def get_job(db: Session, job_id: uuid.UUID) -> PrintJob:
    job = db.get(PrintJob, job_id)
    if job is None:
        raise NotFoundError(meta={"job_id": str(job_id)})
    return job


def _retryable(job: PrintJob) -> bool:
    if job.status == PrintJobStatus.FAILED:
        return True
    # pris par un agent qui n'a jamais rendu de résultat (arrêté pendant l'impression,
    # réponse perdue) : remis en file à la demande, jamais automatiquement (double ticket)
    stale = timedelta(seconds=get_settings().print_job_stale_seconds)
    return (
        job.status == PrintJobStatus.PRINTING
        and job.claimed_at is not None
        and job.claimed_at < _now() - stale
    )


def retry(db: Session, job_id: uuid.UUID, *, user_id: uuid.UUID, ctx: RequestContext) -> PrintJob:
    """Remet le travail en file ; l'agent le reprendra à sa prochaine interrogation."""
    job = print_jobs_repo.get_for_update(db, job_id)
    if job is None:
        raise NotFoundError(meta={"job_id": str(job_id)})
    if not _retryable(job):
        raise PrintJobNotRetryableError(meta={"job_id": str(job_id), "status": job.status})
    before = job.status
    job.status = PrintJobStatus.QUEUED
    job.claimed_at = None
    job.terminal_id = None
    audit_service.log(
        db,
        "print_job.retry",
        ctx=ctx,
        user_id=user_id,
        entity="print_job",
        entity_id=job.id,
        before={"status": before},
        after={"status": job.status, "attempts": job.attempts},
    )
    db.commit()
    return job


def list_jobs(db: Session, *, status: PrintJobStatus | None, page: PageRequest) -> list[PrintJob]:
    return print_jobs_repo.list_jobs(db, status=status, page=page)


def _online_terminal(db: Session) -> tuple[PrintTerminal | None, bool]:
    """(dernier terminal vu, son agent est-il en ligne)."""
    terminal = terminals_repo.latest_seen(db)
    if terminal is None or terminal.last_seen_at is None:
        return terminal, False
    offline_after = timedelta(seconds=get_settings().print_agent_offline_after_seconds)
    return terminal, terminal.last_seen_at >= _now() - offline_after


def status(db: Session) -> PrintingStatusOut:
    terminal, online = _online_terminal(db)
    printer = terminal.printer_status if terminal is not None and online else {}
    return PrintingStatusOut(
        agent_online=online,
        printer_online=bool(printer.get("online")),
        paper=printer.get("paper"),
        width=printer.get("width"),
        agent_last_seen_at=terminal.last_seen_at if terminal is not None else None,
        queued_jobs=print_jobs_repo.queued_count(db),
        failed_jobs=print_jobs_repo.failed_count(db),
        last_success_at=print_jobs_repo.last_success_at(db),
    )


def _require_printer(db: Session) -> None:
    terminal, online = _online_terminal(db)
    if terminal is None or not online:
        raise PrintAgentUnavailableError()
    if terminal.printer_status.get("online") is False:
        raise PrinterUnavailableError()


def request_open_drawer(db: Session, *, user_id: uuid.UUID, ctx: RequestContext) -> PrintJob:
    _require_printer(db)
    job = enqueue(db, job_type=PrintJobType.DRAWER, rendered="", open_drawer=True, user_id=user_id)
    audit_service.log(
        db,
        "printing.open_drawer_manual",
        ctx=ctx,
        user_id=user_id,
        entity="print_job",
        entity_id=job.id,
    )
    db.commit()
    return job


def request_test_print(db: Session, *, user_id: uuid.UUID, ctx: RequestContext) -> PrintJob:
    _require_printer(db)
    rendered = receipt_domain.render_test_ticket(
        # Africa/Abidjan est à UTC toute l'année
        printed_at=f"{_now():%d/%m/%Y %H:%M:%S}",
        width=get_settings().printer_width,
    )
    job = enqueue(
        db, job_type=PrintJobType.TEST, rendered=rendered, open_drawer=False, user_id=user_id
    )
    audit_service.log(
        db, "printing.test", ctx=ctx, user_id=user_id, entity="print_job", entity_id=job.id
    )
    db.commit()
    return job


# --- Agent du terminal ---------------------------------------------------------------------


def claim_next(db: Session, terminal: PrintTerminal, printer: PrinterReport) -> PrintJob | None:
    """Interrogation de l'agent : note sa présence et l'état de l'imprimante, puis lui confie
    le plus ancien travail en file. Rien n'est confié quand l'imprimante est hors ligne : les
    travaux attendent en `QUEUED` au lieu de finir en `FAILED`."""
    terminal.last_seen_at = _now()
    terminal.printer_status = printer.model_dump()
    job = print_jobs_repo.claim_next(db) if printer.online else None
    if job is not None:
        job.status = PrintJobStatus.PRINTING
        job.attempts += 1
        job.claimed_at = terminal.last_seen_at
        job.terminal_id = terminal.id
    db.commit()
    return job


def report_result(
    db: Session,
    terminal: PrintTerminal,
    job_id: uuid.UUID,
    *,
    printed: bool,
    error: str | None,
    ctx: RequestContext,
) -> PrintJob:
    job = print_jobs_repo.get_for_update(db, job_id)
    if job is None:
        raise NotFoundError(meta={"job_id": str(job_id)})
    if job.terminal_id != terminal.id:
        raise PrintJobNotClaimedError(meta={"job_id": str(job_id)})
    final = PrintJobStatus.DONE if printed else PrintJobStatus.FAILED
    if job.status == final:
        return job  # même résultat renvoyé (réponse perdue côté agent) : sans effet
    if job.status != PrintJobStatus.PRINTING:
        raise PrintJobNotClaimedError(meta={"job_id": str(job_id), "status": job.status})
    job.status = final
    job.last_error = None if printed else (error or "Échec signalé par l'agent")[:500]
    audit_service.log(
        db,
        "print_job.print",
        ctx=ctx,
        user_id=None,
        entity="print_job",
        entity_id=job.id,
        after={
            "status": job.status,
            "type": job.type,
            "attempts": job.attempts,
            "terminal": terminal.name,
        },
    )
    db.commit()
    return job
