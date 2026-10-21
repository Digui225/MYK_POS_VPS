from datetime import date
from decimal import Decimal
import pytest
from fastapi.testclient import TestClient

import caisse.models  # Assure que tous les modèles ORM sont enregistrés sur Base.metadata
from caisse.deps import get_current_user
from caisse.domain.enums import (
    CashSessionStatus,
    OrderStatus,
    StockArticleCategory,
    StockMovementType,
    StockOutMode,
)
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.catalog import Category, Product
from caisse.models.order import Order, OrderItem
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.models.user import User
from caisse.schemas.reports import ProteinYieldItem, ProteinYieldReportOut, ProteinYieldTotals
from caisse.services import reporting_service


@pytest.fixture
def auth_responsable(client: TestClient, db_session):
    resp = db_session.query(User).filter_by(role="RESPONSABLE").first()
    from caisse.main import app
    app.dependency_overrides[get_current_user] = lambda: resp
    yield resp
    app.dependency_overrides.pop(get_current_user, None)


def test_export_sales_csv(client: TestClient, auth_responsable):
    response = client.get("/api/v1/reports/sales/export?date_from=2026-10-01&date_to=2026-10-02")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/csv")
    assert "attachment; filename=" in response.headers["content-disposition"]
    text = response.content.decode("utf-8")
    assert "Jour;Date;Commandes;Achats Reçus (XOF)" in text
    assert "TOTAL MENSUEL" in text


def test_export_protein_yields_csv_empty(client: TestClient, auth_responsable):
    response = client.get("/api/v1/reports/protein-yields/export?date_from=2026-10-01&date_to=2026-10-02")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/csv")
    assert "attachment; filename=" in response.headers["content-disposition"]
    text = response.content.decode("utf-8")
    assert "Protéine;Unité;Stock Sorti;Portions Théoriques;Portions Vendues" in text


def test_export_protein_yields_csv_with_items(client: TestClient, auth_responsable, monkeypatch):
    mock_report = ProteinYieldReportOut(
        date_from=date(2026, 10, 1),
        date_to=date(2026, 10, 2),
        totals=ProteinYieldTotals(
            total_consumed_cost_xof=40000,
            total_sold_revenue_xof=123000,
            total_gross_margin_xof=83000,
            total_theoretical_dishes=50,
            total_sold_dishes=41,
            total_variance_dishes=0,
            total_financial_impact_xof=0,
            anomalies_count=0,
        ),
        items=[
            ProteinYieldItem(
                article_id="art-1",
                article_name="Bœuf Filet",
                category="PROTEINE",
                unit="kg",
                avg_cost_xof=4000.0,
                standard_portion=0.2,
                yield_ratio_per_unit=5.0,
                consumed_quantity=10.0,
                consumed_cost_xof=40000,
                theoretical_dishes=50,
                sold_dishes=41,
                sold_revenue_xof=123000,
                gross_margin_xof=83000,
                loss_dishes=9,
                variance_dishes=0,
                financial_impact_xof=0,
                status="NORMAL",
                associated_products=["Steak Frites"],
            )
        ],
    )

    monkeypatch.setattr(reporting_service, "protein_yield_report", lambda *args, **kwargs: mock_report)

    response = client.get("/api/v1/reports/protein-yields/export?date_from=2026-10-01&date_to=2026-10-02")
    assert response.status_code == 200
    text = response.content.decode("utf-8")
    assert "Bœuf Filet;kg;10.0;50;41;9;0;82.0%;0;NORMAL" in text
    assert "TOTAL;—;—;50;41;9;0;82.0%;0;CONFORME" in text


def test_export_protein_yields_csv_real_db(client: TestClient, auth_responsable, db_session):
    day = date(2026, 10, 15)

    # Création du registre et de la session
    register = CashRegister(name="Caisse Export")
    db_session.add(register)
    db_session.flush()

    session = CashSession(
        cash_register_id=register.id,
        opened_by_user_id=auth_responsable.id,
        business_date=day,
        status=CashSessionStatus.CLOSED,
        opening_float_xof=50000,
    )
    db_session.add(session)
    db_session.flush()

    # Catégorie & Produit
    cat = Category(name="Grillades", sort_order=1)
    db_session.add(cat)
    db_session.flush()

    prod = Product(
        name="Pavé de Bœuf",
        short_name="Pave Boeuf",
        category_id=cat.id,
        price_xof=5000,
        vat_rate=Decimal(0),
    )
    db_session.add(prod)
    db_session.flush()

    # Article de stock Protéine
    beef = StockArticle(
        name="Filet de Bœuf",
        category=StockArticleCategory.PROTEINE,
        unit="kg",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal(50),
        avg_cost_xof=Decimal(4000),
    )
    db_session.add(beef)
    db_session.flush()

    # Fiche technique : 0.25 kg par plat (4 portions par kg)
    comp = ProductComponent(
        product_id=prod.id,
        article_id=beef.id,
        quantity=Decimal("0.250"),
    )
    db_session.add(comp)
    db_session.flush()

    # Commande payée de 20 plats
    order = Order(
        order_number="CMD-EXP-001",
        cash_session_id=session.id,
        opened_by_user_id=auth_responsable.id,
        status=OrderStatus.PAID,
        total_ttc_xof=100000,
        total_ht_xof=100000,
        total_vat_xof=0,
        paid_xof=100000,
        due_xof=0,
    )
    db_session.add(order)
    db_session.flush()

    item = OrderItem(
        order_id=order.id,
        product_id=prod.id,
        product_name_snapshot="Pavé de Bœuf",
        category_snapshot="Grillades",
        unit_price_xof=5000,
        quantity=20,
        line_total_xof=100000,
        added_by_user_id=auth_responsable.id,
    )
    db_session.add(item)
    db_session.flush()

    # Mouvement de stock : 5.0 kg sortis
    m_sale = StockMovement(
        article_id=beef.id,
        type=StockMovementType.SALE_OUT,
        quantity=Decimal("-5.000"),
        quantity_after=Decimal("45.000"),
        unit_cost_xof=Decimal(4000),
        business_date=day,
        reference_order_id=order.id,
    )
    db_session.add(m_sale)
    db_session.commit()

    # Appel direct de l'endpoint d'export sans mock
    response = client.get(f"/api/v1/reports/protein-yields/export?date_from={day}&date_to={day}")
    assert response.status_code == 200
    text = response.content.decode("utf-8")
    assert "Filet de Bœuf;kg;5.0;20;20;0;0;100.0%;0;NORMAL" in text
    assert "TOTAL;—;—;20;20;0;0;100.0%;0;CONFORME" in text
