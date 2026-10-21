import uuid
from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import PrintJobStatus, PrintJobType
from caisse.models.print_job import PrintJob
from caisse.pagination import PageRequest, newest_first


def get_for_update(db: Session, job_id: uuid.UUID) -> PrintJob | None:
    return db.scalar(select(PrintJob).where(PrintJob.id == job_id).with_for_update())


def claim_next(db: Session) -> PrintJob | None:
    """Plus ancien travail en file, verrouillé ; `SKIP LOCKED` : deux interrogations
    simultanées ne prennent jamais le même travail."""
    return db.scalar(
        select(PrintJob)
        .where(PrintJob.status == PrintJobStatus.QUEUED)
        .order_by(PrintJob.created_at, PrintJob.id)
        .limit(1)
        .with_for_update(skip_locked=True)
    )


def list_jobs(db: Session, *, status: PrintJobStatus | None, page: PageRequest) -> list[PrintJob]:
    """Une ligne de plus que la page (voir `pagination.split`)."""
    stmt = newest_first(select(PrintJob), PrintJob.created_at, PrintJob.id, page)
    if status is not None:
        stmt = stmt.where(PrintJob.status == status)
    return list(db.scalars(stmt))


def _count(db: Session, status: PrintJobStatus) -> int:
    return int(
        db.scalar(select(func.count()).select_from(PrintJob).where(PrintJob.status == status)) or 0
    )


def queued_count(db: Session) -> int:
    return _count(db, PrintJobStatus.QUEUED)


def failed_count(db: Session) -> int:
    return _count(db, PrintJobStatus.FAILED)


def last_success_at(db: Session) -> datetime | None:
    return db.scalar(
        select(func.max(PrintJob.updated_at)).where(PrintJob.status == PrintJobStatus.DONE)
    )


def latest_receipt_for_order(db: Session, order_id: uuid.UUID) -> PrintJob | None:
    return db.scalar(
        select(PrintJob)
        .where(PrintJob.order_id == order_id, PrintJob.type == PrintJobType.RECEIPT)
        .order_by(PrintJob.created_at.desc())
        .limit(1)
    )
