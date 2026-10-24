from sqlalchemy.orm import Session

from caisse.models.payment import Payment
from caisse.repositories.base import BaseRepository


class PaymentRepository(BaseRepository[Payment]):
    def __init__(self, db: Session):
        super().__init__(db, Payment)

    def list_by_order_id(self, order_id: str) -> list[Payment]:
        return (
            self.db.query(Payment)
            .filter(Payment.order_id == order_id)
            .order_by(Payment.created_at.asc())
            .all()
        )

    def list_by_session_id(self, session_id: str) -> list[Payment]:
        return (
            self.db.query(Payment)
            .filter(Payment.cash_session_id == session_id)
            .order_by(Payment.created_at.asc())
            .all()
        )

    def get_by_idempotency_key(self, key: str) -> Payment | None:
        return self.db.query(Payment).filter(Payment.idempotency_key == key).first()
