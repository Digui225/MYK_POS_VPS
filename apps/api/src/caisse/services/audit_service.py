from typing import Any

from sqlalchemy.orm import Session

from caisse.models.audit import AuditLog
from caisse.repositories.audit import AuditRepository


class AuditService:
    def __init__(self, db: Session):
        self.db = db
        self.repo = AuditRepository(db)

    def log(
        self,
        action: str,
        entity: str,
        entity_id: str | None = None,
        user_id: str | None = None,
        acting_as_user_id: str | None = None,
        before: dict[str, Any] | None = None,
        after: dict[str, Any] | None = None,
        reason: str | None = None,
        device_id: str | None = None,
        ip: str | None = None,
    ) -> AuditLog:
        entry = AuditLog(
            action=action,
            entity=entity,
            entity_id=entity_id,
            user_id=user_id,
            acting_as_user_id=acting_as_user_id,
            before=before,
            after=after,
            reason=reason,
            device_id=device_id,
            ip=ip,
        )
        return self.repo.add(entry)


def log(
    db: Session,
    action: str,
    *,
    entity: str,
    entity_id: str | None = None,
    user_id: str | None = None,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    ctx: Any = None,
    **kwargs: Any,
) -> AuditLog:
    device_id = getattr(ctx, "device_id", None) if ctx else None
    ip = getattr(ctx, "ip", None) if ctx else None
    return AuditService(db).log(
        action=action,
        entity=entity,
        entity_id=str(entity_id) if entity_id else None,
        user_id=str(user_id) if user_id else None,
        before=before,
        after=after,
        device_id=device_id,
        ip=ip,
    )

