from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.models.cash_session import CashMovement, CashRegister, CashSession
from caisse.pagination import PageRequest, newest_first
from caisse.repositories.base import BaseRepository


class CashSessionRepository(BaseRepository[CashSession]):
    def __init__(self, db: Session):
        super().__init__(db, CashSession)

    def get_active_by_register_id(self, register_id: str | None = None) -> CashSession | None:
        if register_id:
            session = (
                self.db.query(CashSession)
                .filter(
                    CashSession.cash_register_id == register_id,
                    CashSession.status != "CLOSED",
                )
                .first()
            )
            if session:
                return session

        return (
            self.db.query(CashSession)
            .filter(CashSession.status != "CLOSED")
            .order_by(CashSession.opened_at.desc())
            .first()
        )

    def get_or_create_default_register(self) -> CashRegister:
        register = self.db.query(CashRegister).first()
        if not register:
            register = CashRegister(
                id="0192384a-3000-7000-8000-000000000001",
                name="Caisse Principale",
                is_active=True,
            )
            self.db.add(register)
            self.db.flush()
        return register

    def get_next_z_number(self, register_id: str) -> int:
        last_session = (
            self.db.query(CashSession)
            .filter(CashSession.cash_register_id == register_id, CashSession.z_number.isnot(None))
            .order_by(CashSession.z_number.desc())
            .first()
        )
        return (last_session.z_number + 1) if (last_session and last_session.z_number) else 1

    def add_movement(self, movement: CashMovement) -> CashMovement:
        self.db.add(movement)
        self.db.flush()
        return movement

    def count_unsettled_orders(self, session_id: str) -> int:
        from caisse.models.order import Order
        return (
            self.db.query(Order)
            .filter(
                Order.cash_session_id == session_id,
                Order.status.in_(["OPEN", "PARTIALLY_PAID"]),
            )
            .count()
        )

    def list_history(
        self,
        register_id: str | None = None,
        page: PageRequest | None = None,
        limit: int | None = None,
    ) -> list[CashSession]:
        if page is not None:
            stmt = newest_first(
                select(CashSession).where(CashSession.status == "CLOSED"),
                CashSession.closed_at,
                CashSession.id,
                page,
            )
        else:
            stmt = (
                select(CashSession)
                .where(CashSession.status == "CLOSED")
                .order_by(CashSession.closed_at.desc(), CashSession.id.desc())
                .limit(limit or 50)
            )
        if register_id is not None:
            stmt = stmt.where(CashSession.cash_register_id == register_id)
        return list(self.db.scalars(stmt).all())
