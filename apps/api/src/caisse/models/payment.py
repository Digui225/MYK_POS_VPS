from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class Payment(Base, TimestampMixin):
    __tablename__ = "payments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    order_id: Mapped[str] = mapped_column(String(36), ForeignKey("orders.id"), nullable=False)
    cash_session_id: Mapped[str] = mapped_column(String(36), ForeignKey("cash_sessions.id"), nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)

    method: Mapped[str] = mapped_column(String(20), nullable=False)
    amount_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    tendered_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    change_xof: Mapped[int | None] = mapped_column(Integer, default=0, nullable=True)

    provider: Mapped[str | None] = mapped_column(String(50), nullable=True)
    reference: Mapped[str | None] = mapped_column(String(100), nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="CAPTURED", nullable=False)
    idempotency_key: Mapped[str | None] = mapped_column(String(100), nullable=True)

    # Relationships
    order = relationship("Order", back_populates="payments")
    cash_session = relationship("CashSession")
    user = relationship("User")
