from datetime import date
from typing import Annotated

from fastapi import APIRouter, Query, status

from caisse.deps import CurrentUser, DbSession, Responsable
from caisse.schemas.finance import (
    BankDepositCreate,
    BankDepositListOut,
    BankDepositOut,
    CashExpenseCreate,
    CashExpenseListOut,
    CashExpenseOut,
)
from caisse.services import finance_service, stock_service

router = APIRouter(prefix="/finance", tags=["Finance & Décaissements"])

DateFrom = Annotated[date | None, Query(description="Première journée incluse")]
DateTo = Annotated[date | None, Query(description="Dernière journée incluse")]


@router.post(
    "/expenses",
    response_model=CashExpenseOut,
    status_code=status.HTTP_201_CREATED,
    summary="Enregistrer une dépense d'exploitation / décaissement",
)
def record_expense(
    payload: CashExpenseCreate,
    current_user: CurrentUser,
    db: DbSession,
) -> CashExpenseOut:
    return finance_service.create_expense(db, current_user, payload)


@router.get(
    "/expenses",
    response_model=CashExpenseListOut,
    summary="Lister les dépenses sur une période",
)
def get_expenses(
    current_user: CurrentUser,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
    category: str | None = Query(None, description="Filtrer par catégorie"),
) -> CashExpenseListOut:
    today = stock_service.business_day(db)
    d_to = date_to or today
    d_from = date_from or d_to
    return finance_service.list_expenses(db, d_from, d_to, category=category)


@router.post(
    "/bank-deposits",
    response_model=BankDepositOut,
    status_code=status.HTTP_201_CREATED,
    summary="Enregistrer un bordereau de versement bancaire",
)
def record_bank_deposit(
    payload: BankDepositCreate,
    responsable: Responsable,
    db: DbSession,
) -> BankDepositOut:
    return finance_service.create_bank_deposit(db, responsable, payload)


@router.get(
    "/bank-deposits",
    response_model=BankDepositListOut,
    summary="Lister les versements bancaires sur une période",
)
def get_bank_deposits(
    current_user: CurrentUser,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> BankDepositListOut:
    today = stock_service.business_day(db)
    d_to = date_to or today
    d_from = date_from or d_to
    return finance_service.list_bank_deposits(db, d_from, d_to)
