from datetime import date
from decimal import Decimal
from sqlalchemy.orm import Session

from caisse.domain.enums import (
    CashSessionStatus,
    OrderStatus,
    StockArticleCategory,
    StockMovementType,
    StockOutMode,
)
from caisse.models.catalog import Category, Product
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.order import Order, OrderItem
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.models.user import User
from caisse.security import hash_pin
from caisse.services import reporting_service


def test_protein_yield_report_variance_detection(db_session: Session) -> None:
    # 1. Utilisateur et Caisse
    user = User(
        full_name="Gérant Test",
        role="RESPONSABLE",
        pin_hash=hash_pin("654321"),
    )
    register = CashRegister(name="Caisse 1")
    db_session.add_all([user, register])
    db_session.flush()

    day = date(2026, 10, 10)
    session = CashSession(
        cash_register_id=register.id,
        opened_by_user_id=user.id,
        business_date=day,
        status=CashSessionStatus.CLOSED,
        opening_float_xof=50000,
    )
    db_session.add(session)
    db_session.flush()

    # 2. Catégorie et Produit vendu
    cat = Category(name="Viandes", sort_order=1)
    db_session.add(cat)
    db_session.flush()

    prod = Product(
        name="Plat bœuf",
        short_name="Plat boeuf",
        category_id=cat.id,
        price_xof=3000,
        vat_rate=Decimal(0),
    )
    db_session.add(prod)
    db_session.flush()

    # 3. Article de stock Bœuf (4 000 FCFA / kg)
    beef = StockArticle(
        name="Bœuf Test",
        category=StockArticleCategory.PROTEINE,
        unit="kg",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal(50),
        avg_cost_xof=Decimal(4000),
    )
    db_session.add(beef)
    db_session.flush()

    # 4. Fiche technique : 1 plat = 0.2 kg (donc 5 plats par kg)
    comp = ProductComponent(
        product_id=prod.id,
        article_id=beef.id,
        quantity=Decimal("0.200"),
    )
    db_session.add(comp)
    db_session.flush()

    # 5. Vente enregistrée : 41 plats vendus
    order = Order(
        order_number="CMD-YIELD-001",
        cash_session_id=session.id,
        opened_by_user_id=user.id,
        status=OrderStatus.PAID,
        total_ttc_xof=41 * 3000,
        total_ht_xof=41 * 3000,
        total_vat_xof=0,
        paid_xof=41 * 3000,
        due_xof=0,
    )
    db_session.add(order)
    db_session.flush()

    item = OrderItem(
        order_id=order.id,
        product_id=prod.id,
        product_name_snapshot="Plat bœuf",
        category_snapshot="Viandes",
        unit_price_xof=3000,
        quantity=41,
        line_total_xof=41 * 3000,
        added_by_user_id=user.id,
    )
    db_session.add(item)
    db_session.flush()

    # 6. Mouvement de stock : 10 kg de bœuf consommés / sortis
    # 41 plats vendus ont sorti 41 * 0.2 = 8.2 kg
    m_sale = StockMovement(
        article_id=beef.id,
        type=StockMovementType.SALE_OUT,
        quantity=Decimal("-8.200"),
        quantity_after=Decimal("41.800"),
        unit_cost_xof=Decimal(4000),
        business_date=day,
        reference_order_id=order.id,
    )
    # Plus une perte constatée ou sortie cuisine supplémentaire de 1.8 kg (total 10 kg sorti)
    m_loss = StockMovement(
        article_id=beef.id,
        type=StockMovementType.LOSS_OUT,
        quantity=Decimal("-1.800"),
        quantity_after=Decimal("40.000"),
        unit_cost_xof=Decimal(4000),
        business_date=day,
        user_id=user.id,
        reason="Viande avariée / perte",
    )
    db_session.add_all([m_sale, m_loss])
    db_session.commit()

    # 7. Exécution du rapport de rendement
    rep = reporting_service.protein_yield_report(db_session, date_from=day, date_to=day)

    assert len(rep.items) >= 1
    beef_row = [i for i in rep.items if i.article_id == beef.id][0]

    assert beef_row.article_name == "Bœuf Test"
    assert beef_row.standard_portion == 0.2
    assert beef_row.yield_ratio_per_unit == 5.0
    assert beef_row.consumed_quantity == 10.0
    assert beef_row.consumed_cost_xof == 40000
    assert beef_row.theoretical_dishes == 50
    assert beef_row.sold_dishes == 41
    assert beef_row.sold_revenue_xof == 123000
    # 1.8 kg de perte déclarée = 9 portions couvertes par la perte
    assert beef_row.loss_dishes == 9
    # 50 théoriques - 41 vendus - 9 pertes déclarées = 0 écart inexpliqué
    assert beef_row.variance_dishes == 0
    assert beef_row.status == "NORMAL"
