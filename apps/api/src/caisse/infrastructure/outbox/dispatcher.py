import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.domain.enums import FneStatus
from caisse.models.fne import FneDocument
from caisse.models.outbox import OutboxEvent
from caisse.repositories.outbox import OutboxRepository

logger = logging.getLogger(__name__)

RETRY_DELAYS = [
    timedelta(seconds=30),
    timedelta(minutes=2),
    timedelta(minutes=10),
    timedelta(minutes=30),
    timedelta(hours=2),
]


def dispatch_event(db: Session, event: OutboxEvent) -> bool:
    """Traite un événement individuel de l'Outbox."""
    from caisse.models.print_job import PrintJob
    from caisse.models.user import User
    from caisse.services.printing_service import PrintingService

    now = datetime.now(timezone.utc)
    event.status = "PROCESSING"
    db.flush()

    try:
        if event.event_type == "PRINT_JOB":
            job = db.query(PrintJob).filter(PrintJob.id == event.aggregate_id).first()
            if not job:
                event.status = "COMPLETED"
                event.processed_at = now
                db.commit()
                return True

            ps = PrintingService(db, agent_url=get_settings().PRINT_AGENT_URL)
            ps._dispatch_job_to_agent(job)
            if job.status == "DONE":
                event.status = "COMPLETED"
                event.processed_at = now
                event.last_error = None
                db.commit()
                return True
            else:
                raise RuntimeError(job.error_message or "Agent d'impression indisponible")

        elif event.event_type == "FNE_CERTIFICATION":
            from caisse.infrastructure.fne import HttpFneProvider, MockFneProvider
            from caisse.services import fne_service

            settings = get_settings()
            provider: Any = None
            if settings.fne_provider == "api":
                provider = HttpFneProvider(settings.fne_api_base_url, settings.fne_api_key)
            elif settings.fne_provider == "mock":
                provider = MockFneProvider()

            # Utilisateur système ou premier administrateur pour l'audit
            admin_user = db.query(User).filter(User.role.in_(["ADMIN", "RESPONSABLE"])).first()
            if not admin_user:
                admin_user = db.query(User).first()

            if admin_user and provider:
                fne_doc = fne_service.retry(
                    db,
                    document_id=event.aggregate_id,
                    provider=provider,
                    user=admin_user,
                    ctx={"source": "outbox_worker"},
                )
                if fne_doc.status == FneStatus.CERTIFIED:
                    event.status = "COMPLETED"
                    event.processed_at = now
                    event.last_error = None
                    db.commit()
                    return True

            raise RuntimeError("Fournisseur FNE non joignable ou échec de certification")

        else:
            # Type d'événement non reconnu, acquitté
            event.status = "COMPLETED"
            event.processed_at = now
            db.commit()
            return True

    except Exception as exc:
        logger.warning(
            "Échec traitement OutboxEvent %s (%s - %s) : %s",
            event.id,
            event.event_type,
            event.aggregate_id,
            exc,
        )
        event.retry_count += 1
        event.last_error = str(exc)

        if event.retry_count >= len(RETRY_DELAYS):
            event.status = "FAILED"
            event.next_retry_at = None
        else:
            event.status = "PENDING"
            delay = RETRY_DELAYS[event.retry_count - 1]
            event.next_retry_at = now + delay

        db.commit()
        return False


def dispatch_pending_outbox_events(db: Session, limit: int = 50) -> dict[str, int]:
    """Scanne et dépile les événements outbox et les factures FNE en attente."""
    repo = OutboxRepository(db)
    pending_events = repo.get_pending_events(limit=limit)

    stats = {"processed": 0, "succeeded": 0, "failed": 0}

    for event in pending_events:
        stats["processed"] += 1
        ok = dispatch_event(db, event)
        if ok:
            stats["succeeded"] += 1
        else:
            stats["failed"] += 1

    # Dépiler également les FneDocuments QUEUED ou PENDING avec backoff dépassé
    now = datetime.now(timezone.utc)
    from caisse.infrastructure.fne import HttpFneProvider, MockFneProvider
    from caisse.models.user import User
    from caisse.services import fne_service

    settings = get_settings()
    provider: Any = None
    if settings.fne_provider == "api":
        provider = HttpFneProvider(settings.fne_api_base_url, settings.fne_api_key)
    elif settings.fne_provider == "mock":
        provider = MockFneProvider()

    if provider:
        admin_user = db.query(User).filter(User.role.in_(["ADMIN", "RESPONSABLE"])).first() or db.query(User).first()
        if admin_user:
            # QUEUED seulement : un document PENDING vient d'être créé par un encaissement qui
            # l'envoie lui-même ; le renvoyer ici ferait deux factures DGI pour une vente.
            pending_docs = (
                db.query(FneDocument)
                .filter(
                    FneDocument.status == FneStatus.QUEUED,
                    FneDocument.is_uncertain == False,
                    FneDocument.next_retry_at.is_(None) | (FneDocument.next_retry_at <= now),
                )
                .limit(limit)
                .all()
            )

            for doc in pending_docs:
                stats["processed"] += 1
                try:
                    res_doc = fne_service.retry(
                        db,
                        document_id=str(doc.id),
                        provider=provider,
                        user=admin_user,
                        ctx={"source": "outbox_fne_retry"},
                    )
                    if res_doc.status == FneStatus.CERTIFIED:
                        stats["succeeded"] += 1
                    else:
                        stats["failed"] += 1
                except Exception as exc:
                    logger.debug("Tentative de renvoi FneDocument %s différée : %s", doc.id, exc)
                    stats["failed"] += 1

    return stats
