from datetime import date, datetime, timezone
from typing import Any

from sqlalchemy import JSON, Boolean, Date, DateTime, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class CashRegister(Base, TimestampMixin):
    __tablename__ = "cash_registers"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    printer_config: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)


class CashSession(Base, TimestampMixin):
    __tablename__ = "cash_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    cash_register_id: Mapped[str] = mapped_column(String(36), ForeignKey("cash_registers.id"), nullable=False)
    opened_by_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    closed_by_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)

    business_date: Mapped[date] = mapped_column(Date, nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="OPEN", nullable=False)

    opening_float_xof: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    z_number: Mapped[int | None] = mapped_column(Integer, nullable=True)
    expected_cash_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    counted_cash_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    variance_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)

    closing_breakdown: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    totals_snapshot: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    notes: Mapped[str | None] = mapped_column(String(500), nullable=True)

    # Relationships
    opened_by = relationship("User", foreign_keys=[opened_by_user_id])
    closed_by = relationship("User", foreign_keys=[closed_by_user_id])
    cash_register = relationship("CashRegister")
    movements = relationship("CashMovement", back_populates="cash_session")

    __table_args__ = (
        Index(
            "uq_cash_register_single_open_session",
            "cash_register_id",
            unique=True,
            postgresql_where=(status != "CLOSED"),
            sqlite_where=(status != "CLOSED"),
        ),
    )


class CashMovement(Base, TimestampMixin):
    __tablename__ = "cash_movements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    cash_session_id: Mapped[str] = mapped_column(String(36), ForeignKey("cash_sessions.id"), nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)

    type: Mapped[str] = mapped_column(String(10), nullable=False)  # IN ou OUT
    amount_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    reason: Mapped[str] = mapped_column(String(255), nullable=False)

    # Relationships
    user = relationship("User")
    cash_session = relationship("CashSession", back_populates="movements")
