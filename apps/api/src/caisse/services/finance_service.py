from datetime import date
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.domain.enums import CashSessionStatus
from caisse.errors import ValidationError
from caisse.models.cash_session import CashMovement, CashSession
from caisse.models.finance import BankDeposit, CashExpense
from caisse.models.user import User
from caisse.schemas.finance import (
    BankDepositCreate,
    BankDepositListOut,
    BankDepositOut,
    CashExpenseCreate,
    CashExpenseListOut,
    CashExpenseOut,
)


def create_expense(db: Session, user: User, payload: CashExpenseCreate) -> CashExpenseOut:
    """Enregistre une dépense opérationnelle et déduit de la session de caisse si demandée."""
    session_id = None
    if payload.deduct_from_cash_session:
        # Trouver la session ouverte active de l'utilisateur ou du restaurant
        session = (
            db.query(CashSession)
            .filter(CashSession.status == CashSessionStatus.OPEN)
            .order_by(CashSession.created_at.desc())
            .first()
        )
        if session:
            session_id = session.id
            # Créer le mouvement de sortie de caisse physique
            movement = CashMovement(
                cash_session_id=session.id,
                user_id=user.id,
                type="OUT",
                amount_xof=payload.amount_xof,
                reason=f"[{payload.category}] {payload.reason}",
            )
            db.add(movement)

    expense = CashExpense(
        business_date=payload.business_date,
        cash_session_id=session_id,
        user_id=user.id,
        category=payload.category,
        amount_xof=payload.amount_xof,
        recipient=payload.recipient,
        reason=payload.reason,
        receipt_reference=payload.receipt_reference,
    )
    db.add(expense)
    db.commit()
    db.refresh(expense)

    return CashExpenseOut(
        id=expense.id,
        business_date=expense.business_date,
        cash_session_id=expense.cash_session_id,
        user_id=expense.user_id,
        user_name=user.full_name,
        category=expense.category,
        amount_xof=expense.amount_xof,
        recipient=expense.recipient,
        reason=expense.reason,
        receipt_reference=expense.receipt_reference,
        created_at=expense.created_at,
    )


def list_expenses(
    db: Session,
    date_from: date,
    date_to: date,
    category: str | None = None,
) -> CashExpenseListOut:
    """Liste les dépenses sur une période."""
    query = (
        db.query(CashExpense)
        .filter(CashExpense.business_date >= date_from, CashExpense.business_date <= date_to)
        .order_by(CashExpense.business_date.desc(), CashExpense.created_at.desc())
    )
    if category:
        query = query.filter(CashExpense.category == category)

    expenses = query.all()

    items = [
        CashExpenseOut(
            id=e.id,
            business_date=e.business_date,
            cash_session_id=e.cash_session_id,
            user_id=e.user_id,
            user_name=e.user.full_name if e.user else "Utilisateur",
            category=e.category,
            amount_xof=e.amount_xof,
            recipient=e.recipient,
            reason=e.reason,
            receipt_reference=e.receipt_reference,
            created_at=e.created_at,
        )
        for e in expenses
    ]

    total_amount = sum(e.amount_xof for e in items)

    return CashExpenseListOut(
        total_count=len(items),
        total_amount_xof=total_amount,
        items=items,
    )


def create_bank_deposit(db: Session, user: User, payload: BankDepositCreate) -> BankDepositOut:
    """Enregistre un versement d'espèces en banque (rapprochement)."""
    deposit = BankDeposit(
        business_date=payload.business_date,
        user_id=user.id,
        amount_xof=payload.amount_xof,
        bank_name=payload.bank_name,
        slip_number=payload.slip_number,
        deposited_by=payload.deposited_by or user.full_name,
        notes=payload.notes,
    )
    db.add(deposit)
    db.commit()
    db.refresh(deposit)

    return BankDepositOut(
        id=deposit.id,
        business_date=deposit.business_date,
        user_id=deposit.user_id,
        user_name=user.full_name,
        amount_xof=deposit.amount_xof,
        bank_name=deposit.bank_name,
        slip_number=deposit.slip_number,
        deposited_by=deposit.deposited_by,
        notes=deposit.notes,
        created_at=deposit.created_at,
    )


def list_bank_deposits(db: Session, date_from: date, date_to: date) -> BankDepositListOut:
    """Liste les bordereaux bancaires sur une période."""
    deposits = (
        db.query(BankDeposit)
        .filter(BankDeposit.business_date >= date_from, BankDeposit.business_date <= date_to)
        .order_by(BankDeposit.business_date.desc(), BankDeposit.created_at.desc())
        .all()
    )

    items = [
        BankDepositOut(
            id=d.id,
            business_date=d.business_date,
            user_id=d.user_id,
            user_name=d.user.full_name if d.user else "Utilisateur",
            amount_xof=d.amount_xof,
            bank_name=d.bank_name,
            slip_number=d.slip_number,
            deposited_by=d.deposited_by,
            notes=d.notes,
            created_at=d.created_at,
        )
        for d in deposits
    ]

    total_amount = sum(d.amount_xof for d in items)

    return BankDepositListOut(
        total_count=len(items),
        total_amount_xof=total_amount,
        items=items,
    )
