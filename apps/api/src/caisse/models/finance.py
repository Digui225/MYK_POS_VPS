from datetime import date

from sqlalchemy import Date, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class CashExpense(Base, TimestampMixin):
    """Dépense d'exploitation / décaissement de caisse (ex: Gaz, emballage, courses d'appoint)."""
    __tablename__ = "cash_expenses"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    business_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    cash_session_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("cash_sessions.id"), nullable=True, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)

    category: Mapped[str] = mapped_column(String(50), nullable=False)  # GAZ, EMBALLAGE, REPARATION, etc.
    amount_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    recipient: Mapped[str | None] = mapped_column(String(100), nullable=True)  # Bénéficiaire
    reason: Mapped[str] = mapped_column(String(255), nullable=False)
    receipt_reference: Mapped[str | None] = mapped_column(String(100), nullable=True)  # N° reçu/facture

    # Relationships
    user = relationship("User", foreign_keys=[user_id])
    cash_session = relationship("CashSession", foreign_keys=[cash_session_id])


class BankDeposit(Base, TimestampMixin):
    """Bordereau de versement bancaire (rapprochement COMPTE BANK)."""
    __tablename__ = "bank_deposits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    business_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)

    amount_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    bank_name: Mapped[str] = mapped_column(String(100), nullable=False)  # BICICI, SIB, etc.
    slip_number: Mapped[str] = mapped_column(String(100), nullable=False)  # N° bordereau versement
    deposited_by: Mapped[str | None] = mapped_column(String(100), nullable=True)
    notes: Mapped[str | None] = mapped_column(String(255), nullable=True)

    # Relationships
    user = relationship("User", foreign_keys=[user_id])
