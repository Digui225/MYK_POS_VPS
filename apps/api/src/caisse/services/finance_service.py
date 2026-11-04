from datetime import date
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse.core import idempotency
from caisse.core.errors import IdempotencyConflictError, NotFoundError, ValidationError
from caisse.domain.enums import CashSessionStatus
from caisse.models.cash_session import CashMovement, CashSession
from caisse.models.finance import BankDeposit, CashExpense, CashRegularization
from caisse.models.user import User
from caisse.schemas.finance import (
    BankDepositCreate,
    BankDepositListOut,
    BankDepositOut,
    CashExpenseCreate,
    CashExpenseListOut,
    CashExpenseOut,
    CashRegularizationCreate,
    CashRegularizationListOut,
    CashRegularizationOut,
)
from caisse.services import audit_service


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


# --- Régularisations d'écart de caisse ---------------------------------------------------


def _regularization_out(reg: CashRegularization) -> CashRegularizationOut:
    return CashRegularizationOut(
        id=reg.id,
        business_date=reg.business_date,
        cash_session_id=reg.cash_session_id,
        z_number=reg.cash_session.z_number if reg.cash_session else None,
        user_id=reg.user_id,
        user_name=reg.user.full_name if reg.user else "Utilisateur",
        amount_xof=reg.amount_xof,
        reason=reg.reason,
        created_at=reg.created_at,
    )


def _closed_session_for(db: Session, payload: CashRegularizationCreate) -> CashSession:
    """Session clôturée du jour à régulariser (le Z n'est pas modifié)."""
    if payload.cash_session_id:
        session = db.get(CashSession, payload.cash_session_id)
        if session is None:
            raise NotFoundError(
                "Session de caisse introuvable.", meta={"cash_session_id": payload.cash_session_id}
            )
        if session.business_date != payload.business_date:
            raise ValidationError(
                "La session indiquée n'appartient pas à cette journée.",
                meta={"cash_session_id": session.id, "business_date": str(payload.business_date)},
            )
    else:
        sessions = (
            db.query(CashSession)
            .filter(CashSession.business_date == payload.business_date)
            .order_by(CashSession.opened_at)
            .all()
        )
        if not sessions:
            raise ValidationError(
                "Aucune session de caisse ce jour-là : rien à régulariser.",
                meta={"business_date": str(payload.business_date)},
            )
        if len(sessions) > 1:
            raise ValidationError(
                "Plusieurs sessions de caisse ce jour-là : précisez laquelle régulariser.",
                meta={"business_date": str(payload.business_date)},
            )
        session = sessions[0]
    if session.status != CashSessionStatus.CLOSED:
        raise ValidationError(
            "La session n'est pas clôturée : corrigez le comptage à la clôture.",
            meta={"cash_session_id": session.id, "status": session.status},
        )
    return session


def create_cash_regularization(
    db: Session,
    user: User,
    payload: CashRegularizationCreate,
    *,
    key: str,
    path: str,
    ctx: Any = None,
) -> tuple[CashRegularizationOut, bool]:
    """Enregistre la régularisation d'un écart de caisse, sans toucher au Z clôturé."""
    request_hash = idempotency.hash_request(payload)
    replay = idempotency.find_replay(db, key, method="POST", path=path, request_hash=request_hash)
    if replay is not None:
        return CashRegularizationOut.model_validate(replay), True
    if payload.amount_xof == 0:
        raise ValidationError("Le montant de la régularisation ne peut pas être nul.")

    session = _closed_session_for(db, payload)
    reg = CashRegularization(
        business_date=payload.business_date,
        cash_session_id=session.id,
        user_id=user.id,
        amount_xof=payload.amount_xof,
        reason=payload.reason.strip(),
    )
    db.add(reg)
    db.flush()
    db.refresh(reg)
    result = _regularization_out(reg)
    audit_service.log(
        db,
        "finance.cash_regularization",
        ctx=ctx,
        user_id=str(user.id),
        entity="cash_session",
        entity_id=str(session.id),
        before={"variance_xof": session.variance_xof},
        after=result.model_dump(mode="json"),
    )
    idempotency.save(
        db,
        key,
        method="POST",
        path=path,
        request_hash=request_hash,
        status=201,
        body=result.model_dump(mode="json"),
        user_id=str(user.id),
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        replay = idempotency.find_replay(
            db, key, method="POST", path=path, request_hash=request_hash
        )
        if replay is None:
            raise IdempotencyConflictError(meta={"key": key}) from None
        return CashRegularizationOut.model_validate(replay), True
    return result, False


def list_cash_regularizations(
    db: Session, date_from: date, date_to: date
) -> CashRegularizationListOut:
    regs = (
        db.query(CashRegularization)
        .filter(
            CashRegularization.business_date >= date_from,
            CashRegularization.business_date <= date_to,
        )
        .order_by(CashRegularization.business_date, CashRegularization.created_at)
        .all()
    )
    items = [_regularization_out(r) for r in regs]
    return CashRegularizationListOut(
        total_count=len(items),
        total_amount_xof=sum(i.amount_xof for i in items),
        items=items,
    )
