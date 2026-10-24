from datetime import datetime, timezone
from typing import Optional

from sqlalchemy.orm import Session

from caisse.models.outbox import OutboxEvent


class OutboxRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, event_id: str) -> Optional[OutboxEvent]:
        return self.db.query(OutboxEvent).filter(OutboxEvent.id == event_id).first()

    def get_pending_events(self, limit: int = 50) -> list[OutboxEvent]:
        now = datetime.now(timezone.utc)
        return (
            self.db.query(OutboxEvent)
            .filter(
                OutboxEvent.status.in_(["PENDING", "PROCESSING"]),
                OutboxEvent.next_retry_at.is_(None) | (OutboxEvent.next_retry_at <= now),
            )
            .order_by(OutboxEvent.created_at.asc())
            .limit(limit)
            .all()
        )

    def add(self, event: OutboxEvent) -> OutboxEvent:
        self.db.add(event)
        self.db.flush()
        return event
