from datetime import date

from sqlalchemy import CheckConstraint, Date, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.core.database import Base
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


class CashRegularization(Base, TimestampMixin):
    """Régularisation d'un écart de caisse constaté à la clôture (Z).

    Le Z clôturé ne change jamais (rien ne se modifie après encaissement) : quand un manque
    est retrouvé (ou un excédent expliqué) après la clôture, on enregistre ici une opération
    tracée, datée du jour de l'écart. Montant signé : positif = argent retrouvé / remis,
    négatif = manque constaté après coup.
    """
    __tablename__ = "cash_regularizations"
    __table_args__ = (CheckConstraint("amount_xof <> 0", name="ck_cash_regularization_amount"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    business_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    cash_session_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("cash_sessions.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    amount_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    reason: Mapped[str] = mapped_column(String(255), nullable=False)

    user = relationship("User", foreign_keys=[user_id])
    cash_session = relationship("CashSession", foreign_keys=[cash_session_id])
