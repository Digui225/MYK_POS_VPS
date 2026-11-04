from datetime import date
from typing import Annotated

from fastapi import APIRouter, Query, Request, Response, status

from caisse.core.deps import Ctx, CurrentUser, DbSession, Responsable
from caisse.core.idempotency import IdempotencyKey, apply_replay_headers
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


@router.post(
    "/cash-regularizations",
    response_model=CashRegularizationOut,
    status_code=status.HTTP_201_CREATED,
    summary="Régulariser un écart de caisse après la clôture",
)
def record_cash_regularization(
    payload: CashRegularizationCreate,
    responsable: Responsable,
    db: DbSession,
    ctx: Ctx,
    request: Request,
    response: Response,
    idempotency_key: IdempotencyKey,
) -> CashRegularizationOut:
    """Argent retrouvé (montant positif) ou manque constaté après coup (négatif) sur une journée
    clôturée. Le Z n'est pas modifié : la régularisation est tracée à côté, avec son motif."""
    result, replayed = finance_service.create_cash_regularization(
        db, responsable, payload, key=idempotency_key, path=request.url.path, ctx=ctx
    )
    if replayed:
        apply_replay_headers(response)
    return result


@router.get(
    "/cash-regularizations",
    response_model=CashRegularizationListOut,
    summary="Lister les régularisations d'écart de caisse sur une période",
)
def get_cash_regularizations(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> CashRegularizationListOut:
    today = stock_service.business_day(db)
    d_to = date_to or today
    d_from = date_from or d_to
    return finance_service.list_cash_regularizations(db, d_from, d_to)
