"""Script de génération de données de simulation (mock) pour valider le flux complet :
Achat marché Économe (vendredi 16h, <= 300 000 XOF) -> Sorties cuisine (Lundi-Vendredi) -> Ventes caisse -> Matrice hebdomadaire.
"""

from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from typing import Any

from sqlalchemy.orm import Session

from caisse.domain.enums import OrderStatus, StockArticleCategory
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.catalog import Product
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.models.production import DailyPreparation, MarketPurchaseItem, MarketPurchaseList
from caisse.models.stock import StockArticle
from caisse.models.table import RestaurantTable
from caisse.models.user import User


def seed_weekly_flow(db: Session, monday_date: date | None = None) -> dict[str, Any]:
    """Génère les données cohérentes pour la semaine allant du lundi au vendredi.
    Par défaut : la semaine du lundi 19 octobre 2026 au vendredi 23 octobre 2026.
    """
    if monday_date is None:
        monday_date = date(2026, 10, 19)

    friday_date = monday_date + timedelta(days=4)

    # 1. Récupération des utilisateurs
    econome = db.query(User).filter(User.role == "ECONOME").first()
    if not econome:
        econome = db.query(User).first()

    caissier = db.query(User).filter(User.role == "CAISSIER").first()
    if not caissier:
        caissier = db.query(User).first()

    responsable = db.query(User).filter(User.role == "RESPONSABLE").first()
    if not responsable:
        responsable = db.query(User).first()

    # 2. Caisse et Table
    cash_register = db.query(CashRegister).filter(CashRegister.is_active == True).first()
    table = db.query(RestaurantTable).filter(RestaurantTable.is_active == True).first()

    if not econome or not caissier or not responsable or not cash_register:
        return {}

    # 3. Récupération des 5 protéines réelles
    articles_map = {
        a.name: a
        for a in db.query(StockArticle)
        .filter(StockArticle.category == StockArticleCategory.PROTEINE)
        .all()
    }

    art_boeuf = articles_map.get("Bœuf") or articles_map.get("Boeuf")
    art_poulet = articles_map.get("Poulet")
    art_mouton = articles_map.get("Mouton")
    art_sosso = articles_map.get("Sosso")
    art_brochet = articles_map.get("Faux brochet")

    assert art_boeuf and art_poulet and art_mouton and art_sosso and art_brochet, (
        "Articles de protéines requis introuvables en base (Bœuf, Poulet, Mouton, Sosso, Faux brochet)."
    )

    # 4. Récupération des plats réels de caisse associés
    def get_prod(name: str) -> Product:
        p = db.query(Product).filter(Product.name == name).first()
        if not p:
            raise ValueError(f"Produit '{name}' introuvable dans le menu.")
        return p

    p_plat_boeuf = get_prod("Plat bœuf")
    p_foufou_boeuf = get_prod("Foufou/foutou bœuf")
    p_plat_poulet = get_prod("Plat poulet")
    p_foufou_poulet = get_prod("Foufou/foutou poulet")
    p_plat_mouton = get_prod("Plat mouton")
    p_foufou_mouton = get_prod("Foufou/foutou mouton")
    p_sosso = get_prod("Sosso 3500")
    p_plat_brochet = get_prod("Plat faux brochet")
    p_foufou_brochet = get_prod("Foufou/foutou faux brochet")

    # 5. Création du Bon d'Achat Marché Économe (Vendredi 16h, <= 300 000 XOF)
    # 20 kg Boeuf (80 000) + 25 Poulet (75 000) + 12 kg Mouton (66 000) + 30 Sosso (46 200) + 30 Brochet (24 000) = 291 200 XOF
    purchase_list = MarketPurchaseList(
        business_date=friday_date,
        status="COMPLETED",
        created_by_user_id=econome.id,
        validated_by_user_id=responsable.id,
        total_budget_xof=291200,
        notes="Achat hebdomadaire marché validé par le patron (Plafond 300 000 XOF)",
    )
    db.add(purchase_list)
    db.flush()

    purchase_items_data = [
        (art_boeuf.id, Decimal("20.000"), 4000, 80000),
        (art_poulet.id, Decimal("25.000"), 3000, 75000),
        (art_mouton.id, Decimal("12.000"), 5500, 66000),
        (art_sosso.id, Decimal("30.000"), 1540, 46200),
        (art_brochet.id, Decimal("30.000"), 800, 24000),
    ]

    for art_id, qty, unit_price, total_cost in purchase_items_data:
        p_item = MarketPurchaseItem(
            purchase_list_id=purchase_list.id,
            article_id=art_id,
            quantity=qty,
            unit_price_xof=unit_price,
            total_price_xof=total_cost,
        )
        db.add(p_item)

    # 6. Du Lundi au Vendredi : Sorties cuisine (matin) et Ventes réelles caisse (service)
    days = [monday_date + timedelta(days=i) for i in range(5)]
    order_counter = 1
    total_sales_xof = 0
    total_dishes_sold = 0

    for d in days:
        day_idx = d.weekday()  # 0=Lundi, 1=Mardi, 2=Mercredi, 3=Jeudi, 4=Vendredi

        # A. Session de caisse journalière fermée
        session = CashSession(
            cash_register_id=cash_register.id,
            opened_by_user_id=caissier.id,
            closed_by_user_id=responsable.id,
            business_date=d,
            status="CLOSED",
            opening_float_xof=50000,
            opened_at=datetime.combine(d, time(11, 0), tzinfo=timezone.utc),
            closed_at=datetime.combine(d, time(16, 0), tzinfo=timezone.utc),
        )
        db.add(session)
        db.flush()

        # B. Sorties cuisine (DailyPreparation)
        # Boeuf : 4 kg / jour -> 20 plats
        # Poulet : 5 pcs / jour -> 20 plats
        # Mouton : 2.4 kg / jour -> 8 ou 9 plats (total 42)
        # Sosso : 6 pcs / jour -> 6 plats
        # Brochet : 6 pcs / jour -> 6 plats
        mouton_dishes = 9 if day_idx in (2, 4) else 8

        preps_data = [
            (art_boeuf.id, Decimal("4.000"), Decimal("5.00"), 20),
            (art_poulet.id, Decimal("5.000"), Decimal("4.00"), 20),
            (art_mouton.id, Decimal("2.400"), Decimal("3.50"), mouton_dishes),
            (art_sosso.id, Decimal("6.000"), Decimal("1.00"), 6),
            (art_brochet.id, Decimal("6.000"), Decimal("1.00"), 6),
        ]

        for a_id, p_qty, p_yield, theo_dishes in preps_data:
            prep = DailyPreparation(
                business_date=d,
                article_id=a_id,
                prepared_quantity=p_qty,
                yield_portions_per_unit=p_yield,
                theoretical_dishes=theo_dishes,
                user_id=econome.id,
                notes=f"Sortie cuisine {d.strftime('%A')}",
            )
            db.add(prep)

        # C. Ventes en caisse par jour
        # Définition des quantités vendues par plat pour ce jour :
        # Mercredi : -1 plat bœuf, -1 plat mouton (perte/écart valorisé)
        # Vendredi : -1 plat poulet (perte/écart valorisé)
        if day_idx == 2:  # Mercredi
            sales_plan = [
                (p_plat_boeuf, 14),
                (p_foufou_boeuf, 5),
                (p_plat_poulet, 15),
                (p_foufou_poulet, 5),
                (p_plat_mouton, 6),
                (p_foufou_mouton, 2),  # 8 vendus sur 9 prévus
                (p_sosso, 6),
                (p_plat_brochet, 4),
                (p_foufou_brochet, 2),
            ]
        elif day_idx == 4:  # Vendredi
            sales_plan = [
                (p_plat_boeuf, 15),
                (p_foufou_boeuf, 5),
                (p_plat_poulet, 14),  # 19 vendus sur 20 prévus
                (p_foufou_poulet, 5),
                (p_plat_mouton, 7),
                (p_foufou_mouton, 2),
                (p_sosso, 6),
                (p_plat_brochet, 4),
                (p_foufou_brochet, 2),
            ]
        else:  # Lundi, Mardi, Jeudi (0 écart)
            sales_plan = [
                (p_plat_boeuf, 15),
                (p_foufou_boeuf, 5),
                (p_plat_poulet, 15),
                (p_foufou_poulet, 5),
                (p_plat_mouton, 6),
                (p_foufou_mouton, 2),
                (p_sosso, 6),
                (p_plat_brochet, 4),
                (p_foufou_brochet, 2),
            ]

        # Regrouper les ventes en plusieurs commandes clients de midi
        order_groups = []
        current_group = []
        for prod, count in sales_plan:
            for _ in range(count):
                current_group.append(prod)
                if len(current_group) >= 3:  # 3 plats par commande en moyenne
                    order_groups.append(current_group)
                    current_group = []
        if current_group:
            order_groups.append(current_group)

        order_time = datetime.combine(d, time(12, 0), tzinfo=timezone.utc)
        for group in order_groups:
            order_num = f"CMD-{d.strftime('%Y%m%d')}-{order_counter:04d}"
            order_counter += 1

            total_ttc = sum(p.price_xof for p in group)
            total_sales_xof += total_ttc
            total_dishes_sold += len(group)

            order = Order(
                order_number=order_num,
                cash_session_id=session.id,
                table_id=table.id if table else None,
                status=OrderStatus.PAID,
                opened_by_user_id=caissier.id,
                closed_by_user_id=caissier.id,
                guests_count=len(group),
                total_ttc_xof=total_ttc,
                total_ht_xof=total_ttc,
                total_vat_xof=0,
                paid_xof=total_ttc,
                due_xof=0,
                opened_at=order_time,
                paid_at=order_time + timedelta(minutes=25),
            )
            db.add(order)
            db.flush()

            for prod in group:
                item = OrderItem(
                    order_id=order.id,
                    product_id=prod.id,
                    product_name_snapshot=prod.name,
                    category_snapshot="PLATS",
                    unit_price_xof=prod.price_xof,
                    quantity=1,
                    line_total_xof=prod.price_xof,
                    added_by_user_id=caissier.id,
                    added_at=order_time,
                )
                db.add(item)

            payment = Payment(
                order_id=order.id,
                cash_session_id=session.id,
                user_id=caissier.id,
                method="CASH",
                amount_xof=total_ttc,
                tendered_xof=total_ttc,
                change_xof=0,
                status="CAPTURED",
            )
            db.add(payment)

            order_time += timedelta(minutes=4)

    db.commit()

    return {
        "start_date": monday_date.isoformat(),
        "end_date": friday_date.isoformat(),
        "total_purchases_xof": 291200,
        "total_sales_xof": total_sales_xof,
        "total_dishes_sold": total_dishes_sold,
        "variance_dishes": 3,
        "variance_loss_xof": 10000,
    }
