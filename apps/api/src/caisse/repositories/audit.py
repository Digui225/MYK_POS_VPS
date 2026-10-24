from sqlalchemy.orm import Session

from caisse.models.audit import AuditLog
from caisse.repositories.base import BaseRepository


class AuditRepository(BaseRepository[AuditLog]):
    def __init__(self, db: Session):
        super().__init__(db, AuditLog)
