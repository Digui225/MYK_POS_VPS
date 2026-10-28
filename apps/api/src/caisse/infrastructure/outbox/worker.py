import asyncio
import logging
import time

from caisse.database import SessionLocal
from caisse.infrastructure.outbox.dispatcher import dispatch_pending_outbox_events

logger = logging.getLogger("caisse.outbox.worker")


def _dispatch_once() -> dict[str, int]:
    db = SessionLocal()
    try:
        return dispatch_pending_outbox_events(db, limit=25)
    finally:
        db.close()


async def run_outbox_worker_loop(stop_event: asyncio.Event, interval_seconds: float = 30.0) -> None:
    """Boucle asynchrone pour dépiler l'outbox en tâche de fond de l'application FastAPI."""
    logger.info("Démarrage du worker Outbox d'arrière-plan (intervalle: %ss)", interval_seconds)
    while not stop_event.is_set():
        try:
            # Dans un thread : les appels HTTP à la FNE (jusqu'au délai d'attente) bloqueraient
            # sinon toute l'API pendant leur durée.
            stats = await asyncio.to_thread(_dispatch_once)
            if stats["processed"] > 0:
                logger.info("Outbox dépilé : %s", stats)
        except Exception as exc:
            logger.error("Erreur dans le cycle du worker Outbox : %s", exc)

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval_seconds)
        except asyncio.TimeoutError:
            pass

    logger.info("Arrêt du worker Outbox d'arrière-plan.")


def run_outbox_worker_sync(once: bool = False, interval_seconds: float = 30.0) -> None:
    """Exécution synchrone du worker pour les processus dédiés (CLI / conteneur worker)."""
    logger.info("Démarrage du worker Outbox synchrone (once=%s)", once)
    while True:
        try:
            db = SessionLocal()
            try:
                stats = dispatch_pending_outbox_events(db, limit=50)
                if stats["processed"] > 0:
                    logger.info("Outbox dépilé : %s", stats)
            finally:
                db.close()
        except Exception as exc:
            logger.error("Erreur worker Outbox : %s", exc)

        if once:
            break

        time.sleep(interval_seconds)
