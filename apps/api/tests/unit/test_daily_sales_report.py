from datetime import date
from decimal import Decimal
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    CashSessionStatus,
    OrderStatus,
    PaymentMethod,
    PaymentStatus,
    StockArticleCategory,
    StockMovementType,
    StockOutMode,
)
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.user import User
from caisse.security import hash_pin
from caisse.services import reporting_service


def test_sales_report_daily_breakdown_metrics(db_session: Session) -> None:
    # 1. Setup user and register
    user = User(
        full_name="Test Responsable",
        role="RESPONSABLE",
        pin_hash=hash_pin("654321"),
    )
    register = CashRegister(name="Caisse 1")
    db_session.add_all([user, register])
    db_session.flush()

    # 2. Setup cash session on 2026-10-10
    day = date(2026, 10, 10)
    session = CashSession(
        cash_register_id=register.id,
        opened_by_user_id=user.id,
        business_date=day,
        status=CashSessionStatus.CLOSED,
        opening_float_xof=50000,
        expected_cash_xof=150000,
        counted_cash_xof=148000,
        variance_xof=-2000,
    )
    db_session.add(session)
    db_session.flush()

    # 3. Setup paid order of 100,000 XOF
    order = Order(
        order_number="CMD-20261010-001",
        cash_session_id=session.id,
        opened_by_user_id=user.id,
        status=OrderStatus.PAID,
        total_ttc_xof=100000,
        total_ht_xof=100000,
        total_vat_xof=0,
        paid_xof=100000,
        due_xof=0,
    )
    db_session.add(order)
    db_session.flush()

    # 4. Setup stock article and movements
    art = StockArticle(
        name="Mouton Test",
        category=StockArticleCategory.PROTEINE,
        unit="kg",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal(20),
        avg_cost_xof=Decimal(5000),
    )
    db_session.add(art)
    db_session.flush()

    # Purchase: 10 kg @ 5000 = 50,000 XOF
    m_purch = StockMovement(
        article_id=art.id,
        type=StockMovementType.PURCHASE_IN,
        quantity=Decimal(10),
        quantity_after=Decimal(30),
        unit_cost_xof=Decimal(5000),
        business_date=day,
        user_id=user.id,
    )
    # Sale out via recipe: 5 kg @ 5000 = 25,000 XOF
    m_sale = StockMovement(
        article_id=art.id,
        type=StockMovementType.SALE_OUT,
        quantity=Decimal(-5),
        quantity_after=Decimal(25),
        unit_cost_xof=Decimal(5000),
        business_date=day,
        reference_order_id=order.id,
    )
    # Loss: 1 kg @ 5000 = 5,000 XOF
    m_loss = StockMovement(
        article_id=art.id,
        type=StockMovementType.LOSS_OUT,
        quantity=Decimal(-1),
        quantity_after=Decimal(24),
        unit_cost_xof=Decimal(5000),
        business_date=day,
        user_id=user.id,
    )
    db_session.add_all([m_purch, m_sale, m_loss])
    db_session.commit()

    # 5. Execute sales report for 2026-10-10
    report = reporting_service.sales_report(db_session, date_from=day, date_to=day)

    # Check totals
    assert report.totals.revenue_xof == 100000
    assert report.totals.orders_count == 1

    # Check daily breakdown
    assert len(report.by_day) == 1
    d_row = report.by_day[0]
    assert d_row.business_date == day
    assert d_row.revenue_xof == 100000
    assert d_row.recipe_cost_xof == 25000
    assert d_row.recipe_margin_xof == 75000
    assert d_row.purchases_xof == 50000
    assert d_row.inventory_consumption_xof == 5000
    # gross_margin = revenue (100000) - recipe_cost (25000) - non_sale (5000) = 70000
    assert d_row.gross_margin_xof == 70000
    assert d_row.gross_margin_rate == 70.0
    assert d_row.expected_cash_xof == 150000
    assert d_row.counted_cash_xof == 148000
    assert d_row.cash_variance_xof == -2000
