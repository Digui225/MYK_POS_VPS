from datetime import date
from sqlalchemy.orm import Session

from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.finance import BankDeposit, CashExpense
from caisse.models.user import User
from caisse.schemas.finance import BankDepositCreate, CashExpenseCreate
from caisse.security import hash_pin
from caisse.services import finance_service, reporting_service


def test_expenses_and_bank_deposits_lifecycle(db_session: Session) -> None:
    # 1. Création utilisateur et session ouverte
    user = User(
        full_name="Gérant Test",
        role="RESPONSABLE",
        pin_hash=hash_pin("654321"),
    )
    register = CashRegister(name="Caisse Principale")
    db_session.add_all([user, register])
    db_session.flush()

    day = date(2026, 10, 15)
    session = CashSession(
        cash_register_id=register.id,
        opened_by_user_id=user.id,
        business_date=day,
        status="OPEN",
        opening_float_xof=50000,
    )
    db_session.add(session)
    db_session.flush()

    # 2. Enregistrement d'une dépense avec déduction de caisse
    expense_payload = CashExpenseCreate(
        business_date=day,
        category="GAZ",
        amount_xof=14500,
        reason="Achat bouteille de gaz cuisine",
        recipient="Livreur Gaz B12",
        receipt_reference="REC-GAZ-01",
        deduct_from_cash_session=True,
    )
    created_expense = finance_service.create_expense(db_session, user, expense_payload)

    assert created_expense.amount_xof == 14500
    assert created_expense.category == "GAZ"
    assert created_expense.cash_session_id == session.id

    # Vérification que le mouvement de caisse OUT a été créé
    assert len(session.movements) == 1
    assert session.movements[0].type == "OUT"
    assert session.movements[0].amount_xof == 14500

    # 3. Enregistrement d'un versement bancaire
    deposit_payload = BankDepositCreate(
        business_date=day,
        amount_xof=180000,
        bank_name="BICICI",
        slip_number="SLIP-2026-0042",
        deposited_by="Koffi Messager",
        notes="Versement recettes de la veille",
    )
    created_deposit = finance_service.create_bank_deposit(db_session, user, deposit_payload)

    assert created_deposit.amount_xof == 180000
    assert created_deposit.bank_name == "BICICI"
    assert created_deposit.slip_number == "SLIP-2026-0042"

    # 4. Liste des dépenses et des versements
    expenses_list = finance_service.list_expenses(db_session, day, day)
    assert expenses_list.total_count == 1
    assert expenses_list.total_amount_xof == 14500

    deposits_list = finance_service.list_bank_deposits(db_session, day, day)
    assert deposits_list.total_count == 1
    assert deposits_list.total_amount_xof == 180000

    # 5. Vérification de l'intégration dans le rapport de ventes mensuel
    report = reporting_service.sales_report(db_session, day, day)
    assert len(report.by_day) == 1
    day_report = report.by_day[0]

    assert day_report.expenses_xof == 14500
    assert day_report.bank_deposit_xof == 180000
    # Résultat net = Marge brute - Dépenses
    assert day_report.net_result_xof == day_report.gross_margin_xof - 14500
    assert report.totals.expenses_xof == 14500
    assert report.totals.bank_deposit_xof == 180000
