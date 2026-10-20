from typing import Any

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import func, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.domain.enums import FneStatus
from caisse.models.fne import FneDocument
from caisse.services import printing_service

router = APIRouter(tags=["Santé"])

FNE_PENDING = (FneStatus.PENDING, FneStatus.QUEUED, FneStatus.SUBMITTING, FneStatus.FAILED)


@router.get("/health", summary="Le service répond")
def health() -> dict[str, str]:
    """Liveness : le processus répond. Utilisé par le bandeau de connexion du front."""
    return {"status": "ok"}


@router.get("/health/ready", summary="Le service est prêt à vendre")
def ready(db: Session = Depends(get_db)) -> JSONResponse:
    """Readiness : la base est indispensable ; l'imprimante et les files sont informatives
    (une imprimante absente ne bloque jamais la vente)."""
    body: dict[str, Any] = {"status": "ok"}
    try:
        db.execute(text("SELECT 1"))
        body["database"] = "ok"
        printing = printing_service.status(db)
        body["queues"] = {
            "print_queued": printing.queued_jobs,
            "print_failed": printing.failed_jobs,
            "fne_pending": db.scalar(
                select(func.count())
                .select_from(FneDocument)
                .where(FneDocument.status.in_(FNE_PENDING))
            ),
        }
        body["printer"] = {
            "agent_online": printing.agent_online,
            "printer_online": printing.printer_online,
            "paper": printing.paper,
        }
    except SQLAlchemyError:
        # l'état de l'agent est en base : inconnu quand elle ne répond pas
        body.update(
            status="unavailable",
            database="unreachable",
            printer={"agent_online": False, "printer_online": False, "paper": None},
        )
    return JSONResponse(body, status_code=200 if body["status"] == "ok" else 503)
