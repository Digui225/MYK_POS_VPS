from datetime import datetime
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from caisse.models.print_job import PrintJob
from caisse.pagination import PageRequest, newest_first
from caisse.repositories.base import BaseRepository


class PrintJobRepository(BaseRepository[PrintJob]):
    def __init__(self, db: Session):
        super().__init__(db, PrintJob)

    def list_queued(self, limit: int = 10) -> list[PrintJob]:
        return (
            self.db.query(PrintJob)
            .filter(PrintJob.status == "QUEUED")
            .order_by(PrintJob.created_at.asc())
            .limit(limit)
            .all()
        )

    def list_by_order_id(self, order_id: str) -> list[PrintJob]:
        return (
            self.db.query(PrintJob)
            .filter(PrintJob.order_id == order_id)
            .order_by(PrintJob.created_at.desc())
            .all()
        )

    def claim_next(self) -> PrintJob | None:
        """Sélectionne le plus ancien travail en file pour exécution par l'agent."""
        stmt = (
            select(PrintJob)
            .where(PrintJob.status == "QUEUED")
            .order_by(PrintJob.created_at.asc())
            .limit(1)
        )
        try:
            stmt = stmt.with_for_update(skip_locked=True)
            return self.db.scalar(stmt)
        except Exception:
            # Fallback pour SQLite en test
            return self.db.scalar(
                select(PrintJob)
                .where(PrintJob.status == "QUEUED")
                .order_by(PrintJob.created_at.asc())
                .limit(1)
            )

    def get_for_update(self, job_id: str) -> PrintJob | None:
        try:
            return self.db.scalar(
                select(PrintJob).where(PrintJob.id == job_id).with_for_update()
            )
        except Exception:
            return self.db.get(PrintJob, job_id)

    def queued_count(self) -> int:
        return self.db.scalar(
            select(func.count(PrintJob.id)).where(PrintJob.status == "QUEUED")
        ) or 0

    def failed_count(self) -> int:
        return self.db.scalar(
            select(func.count(PrintJob.id)).where(PrintJob.status == "FAILED")
        ) or 0

    def last_success_at(self) -> datetime | None:
        return self.db.scalar(
            select(func.max(PrintJob.printed_at)).where(PrintJob.status == "DONE")
        )

    def list_jobs(
        self,
        status: str | None = None,
        page: PageRequest | None = None,
        limit: int | None = None,
    ) -> list[PrintJob]:
        if page is not None:
            stmt = newest_first(select(PrintJob), PrintJob.created_at, PrintJob.id, page)
        else:
            stmt = select(PrintJob).order_by(PrintJob.created_at.desc(), PrintJob.id.desc()).limit(limit or 50)
        if status:
            stmt = stmt.where(PrintJob.status == status)
        return list(self.db.scalars(stmt).all())
