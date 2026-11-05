"""Règle universelle du stock protéines (D6) : la matrice de contrôle et le stock sont au même
niveau, quels que soient les mouvements (achats de tous circuits, ventes du menu et hors menu,
pertes, inventaires, corrections), et la sortie cuisine n'est qu'un contrôle."""

import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.domain.enums import CashSessionStatus, OrderStatus
from caisse.models.cash_session import CashSession
from caisse.models.catalog import Category, Product
from caisse.models.order import Order, OrderItem
from caisse.models.production import DailyPreparation
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.services import reporting_service
from caisse.services.production_service import get_weekly_matrix


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}


def _assert_ledger_identity(row: Any) -> None:
    """Restant = Ouverture + Achats − Ventes − Pertes ± Inventaire ± Corrections, jour par jour,
    et le restant de fin de période est le stock."""
    previous_closing = row.opening_stock_qty
    for d in row.days:
        assert d.opening_quantity == previous_closing
        expected = round(
            d.opening_quantity
            + d.purchased_quantity
            - d.stock_sold_quantity
            - d.loss_quantity
            + d.inventory_variance_quantity
            + d.correction_quantity,
            3,
        )
        assert d.closing_quantity == expected
        assert d.remaining_quantity == round(d.opening_quantity + d.purchased_quantity, 3)
        previous_closing = d.closing_quantity
    assert row.closing_stock_qty == previous_closing


def _sell(client: TestClient, headers: dict[str, str], key: str, lines: list[dict[str, Any]]) -> None:
    oid = client.post(
        "/api/v1/orders", headers=headers, json={"table_id": "tbl-01", "guests_count": 1}
    ).json()["id"]
    total = 0
    for line in lines:
        res = client.post(f"/api/v1/orders/{oid}/items", headers=headers, json=line)
        assert res.status_code in (200, 201), res.text
        total += line.get("unit_price_xof", 3500) * line["quantity"]
    order = client.get(f"/api/v1/orders/{oid}", headers=headers).json()
    due = order.get("due_xof", total)
    pay = client.post(
        f"/api/v1/orders/{oid}/payments",
        headers={**headers, "Idempotency-Key": f"pay-{key}"},
        json={"method": "CASH", "amount_xof": due, "tendered_xof": due},
    )
    assert pay.status_code == 201, pay.text


def _open(client: TestClient, headers: dict[str, str], day: str) -> str:
    res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": f"sess-{day}-{uuid.uuid4()}"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 10000, "business_date": day},
    )
    assert res.status_code == 201, res.text
    return str(res.json()["id"])


def _close(client: TestClient, headers: dict[str, str], session_id: str) -> None:
    res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": f"close-{session_id}"},
        json={"counted_breakdown": {"10000": 1}},
    )
    assert res.status_code == 200, res.text


def test_matrice_egale_au_stock_avec_tous_les_mouvements(
    client: TestClient, db_session: Session
) -> None:
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")

    saumon = StockArticle(
        name="Saumon", category="PROTEINE", unit="morceau", out_mode="RECIPE",
        quantity=Decimal(0), avg_cost_xof=Decimal(500), is_active=True,
    )
    cat = Category(id="cat-led", name="Plats", kind="DISH")
    tchep = Product(
        id="prod-tchep-saumon", category_id="cat-led", name="Tchep+Saumon",
        short_name="Tchep saumon", price_xof=3500, is_active=True,
    )
    db_session.add_all([saumon, cat, tchep])
    db_session.flush()
    db_session.add(ProductComponent(product_id=tchep.id, article_id=saumon.id, quantity=Decimal(1)))
    db_session.commit()
    sid = str(saumon.id)

    # Vendredi 06/11 : inventaire de départ 6, bon marché de 14
    res = client.post(
        "/api/v1/stock/counts",
        headers={**resp, "Idempotency-Key": "led-open"},
        json={"business_date": "2026-11-06", "lines": [{"article_id": sid, "counted_quantity": 6}]},
    )
    assert res.status_code == 201, res.text
    bon = client.post(
        "/api/v1/production/market-purchases",
        headers=caissier,
        json={"business_date": "2026-11-06",
              "items": [{"article_id": sid, "quantity": 14, "unit_price_xof": 500}]},
    ).json()
    assert client.post(
        f"/api/v1/production/market-purchases/{bon['id']}/complete", headers=resp
    ).status_code == 200
    assert client.post(
        f"/api/v1/production/market-purchases/{bon['id']}/receive", headers=resp, json={}
    ).status_code == 200

    # Lundi 09/11 : 2 plats du menu + 1 plat hors menu, perte de 1, inventaire 12 (−4)
    s1 = _open(client, caissier, "2026-11-09")
    _sell(client, caissier, "led-1", [
        {"product_id": tchep.id, "quantity": 2},
        {"custom_name": "Foutou saumon", "unit_price_xof": 3500, "quantity": 1},
    ])
    assert client.post(
        "/api/v1/stock/losses",
        headers={**resp, "Idempotency-Key": "led-loss"},
        json={"business_date": "2026-11-09", "reason": "Repas du personnel",
              "lines": [{"article_id": sid, "quantity": 1}]},
    ).status_code == 201
    assert client.post(
        "/api/v1/stock/counts",
        headers={**resp, "Idempotency-Key": "led-count"},
        json={"business_date": "2026-11-09", "lines": [{"article_id": sid, "counted_quantity": 12}]},
    ).status_code == 201
    _close(client, caissier, s1)

    # Mardi 10/11 : entrée manuelle de 2 (hors bon), 1 plat vendu, correction de −1 sans commande
    s2 = _open(client, caissier, "2026-11-10")
    assert client.post(
        "/api/v1/stock/receipts",
        headers={**resp, "Idempotency-Key": "led-rec"},
        json={"business_date": "2026-11-10", "supplier": "Marché",
              "lines": [{"article_id": sid, "quantity": 2, "total_cost_xof": 1000}]},
    ).status_code == 201
    _sell(client, caissier, "led-2", [{"product_id": tchep.id, "quantity": 1}])
    _close(client, caissier, s2)
    db_session.expire_all()
    art = db_session.get(StockArticle, sid)
    assert art is not None
    art.quantity = art.quantity - 1
    db_session.add(StockMovement(
        article_id=sid, type="SALE_OUT", quantity=Decimal("-1"), quantity_after=art.quantity,
        unit_cost_xof=Decimal(500), business_date=date(2026, 11, 10),
        reason="Rattrapage (migration)", created_at=datetime.now(timezone.utc),
    ))
    db_session.commit()

    matrix = get_weekly_matrix(db_session, date(2026, 11, 9), date(2026, 11, 13))
    row = next(r for r in matrix.rows if r.article_id == sid)
    _assert_ledger_identity(row)

    # La matrice et le stock sont au même niveau
    assert row.closing_stock_qty == row.current_stock_qty == 12.0
    assert row.opening_stock_qty == 20.0
    assert row.weekly_purchased_qty == 2.0  # l'entrée manuelle compte comme achat
    lundi, mardi = row.days[0], row.days[1]
    assert (lundi.stock_sold_quantity, lundi.loss_quantity, lundi.inventory_variance_quantity) == (
        3.0, 1.0, -4.0,
    )
    assert lundi.closing_quantity == 12.0
    assert lundi.sold_dishes == 3
    assert lundi.non_destocked_dishes == 0  # le hors menu est bien déstocké
    assert (mardi.purchased_quantity, mardi.stock_sold_quantity, mardi.correction_quantity) == (
        2.0, 1.0, -1.0,
    )
    assert row.total_correction_qty == -1.0
    assert row.total_inventory_variance_qty == -4.0
    assert row.total_loss_qty == 1.0

    # Sortie cuisine : estimation à la clôture, sans effet sur le stock
    assert lundi.preparation_status == "ESTIMATED"
    assert lundi.prepared_quantity == 3.0
    assert lundi.preparation_gap_quantity == 0.0

    # Rapport de stock : la correction n'est pas une vente
    stock = reporting_service.stock_report(db_session, date(2026, 11, 9), date(2026, 11, 13))
    srow = next(a for a in stock.articles if a.article_id == sid)
    assert srow.sold_quantity == 4.0
    assert srow.correction_quantity == -1.0
    assert srow.count_adjustment_quantity == -4.0
    assert srow.closing_quantity == 12.0

    # Rendements : consommation = ventes 4 + perte 1 + manquant 4 + correction 1
    yields = reporting_service.protein_yield_report(db_session, date(2026, 11, 9), date(2026, 11, 13))
    yrow = next(i for i in yields.items if i.article_id == sid)
    assert yrow.consumed_quantity == 10.0
    assert yrow.sold_dishes == 4


def test_cycle_des_etats_de_la_sortie_cuisine(client: TestClient, db_session: Session) -> None:
    caissier = _headers(client, "123456")
    poulet = StockArticle(
        name="Poulet", category="PROTEINE", unit="pièce", out_mode="RECIPE",
        quantity=Decimal(10), avg_cost_xof=Decimal(3000), is_active=True,
    )
    db_session.add(poulet)
    db_session.commit()
    pid = str(poulet.id)

    s1 = _open(client, caissier, "2026-11-16")
    _sell(client, caissier, "prep-1", [
        {"custom_name": "Poulet braisé", "unit_price_xof": 3000, "quantity": 8}
    ])
    _close(client, caissier, s1)

    def prep() -> DailyPreparation:
        db_session.expire_all()
        p = db_session.query(DailyPreparation).filter_by(article_id=pid).one()
        return p

    # 8 plats × 0,25 = 2 poulets estimés
    assert (prep().status, float(prep().prepared_quantity)) == ("ESTIMATED", 2.0)
    stock_before = float(db_session.get(StockArticle, pid).quantity)  # type: ignore[union-attr]

    # « Valider la journée »
    res = client.post(
        "/api/v1/production/daily-preparations/validate-day",
        headers=caissier, json={"business_date": "2026-11-16"},
    )
    assert res.status_code == 200, res.text
    assert res.json()["validated_count"] == 1
    assert prep().status == "VALIDATED"

    # La cuisine ajuste : 3 poulets réellement sortis
    res = client.post(
        "/api/v1/production/daily-preparations",
        headers=caissier,
        json={"business_date": "2026-11-16", "article_id": pid,
              "prepared_quantity": 3, "yield_portions_per_unit": 4},
    )
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "ADJUSTED"
    assert res.json()["estimated_quantity"] == 2.0

    # Une nouvelle clôture le même jour n'écrase pas l'ajustement, seule l'estimation bouge
    s2 = _open(client, caissier, "2026-11-16")
    _sell(client, caissier, "prep-2", [
        {"custom_name": "Poulet braisé", "unit_price_xof": 3000, "quantity": 4}
    ])
    _close(client, caissier, s2)
    p = prep()
    assert (p.status, float(p.prepared_quantity), float(p.estimated_quantity or 0)) == (
        "ADJUSTED", 3.0, 3.0,
    )

    # La sortie cuisine ne touche jamais le stock : seules les ventes l'ont fait baisser (−1)
    db_session.expire_all()
    assert float(db_session.get(StockArticle, pid).quantity) == stock_before - 1.0  # type: ignore[union-attr]

    # Confirmer le chiffre estimé → VALIDÉE
    res = client.post(
        "/api/v1/production/daily-preparations",
        headers=caissier,
        json={"business_date": "2026-11-16", "article_id": pid,
              "prepared_quantity": 3, "yield_portions_per_unit": 4},
    )
    assert res.json()["status"] == "VALIDATED"

    matrix = get_weekly_matrix(db_session, date(2026, 11, 16), date(2026, 11, 20))
    lundi = next(r for r in matrix.rows if r.article_id == pid).days[0]
    assert lundi.preparation_status == "VALIDATED"
    assert lundi.stock_sold_quantity == 3.0
    assert lundi.preparation_gap_quantity == 0.0


def test_semaine_reelle_du_saumon_matrice_et_stock_a_2(db_session: Session) -> None:
    """Rejeu de la production (02-03/11/2026) : la matrice affichait 10, le stock 2.
    Désormais la matrice lit l'inventaire du lundi soir (−7) et trouve 2, comme le stock."""
    saumon = StockArticle(
        name="Saumon", category="PROTEINE", unit="morceau", out_mode="RECIPE",
        quantity=Decimal(2), avg_cost_xof=Decimal(500), is_active=True,
    )
    cat = Category(id="cat-sau", name="Plats", kind="DISH")
    tchep = Product(id="p-tchep", category_id="cat-sau", name="Tchep+Saumon",
                    short_name="Tchep", price_xof=3500, is_active=True)
    db_session.add_all([saumon, cat, tchep])
    db_session.flush()
    db_session.add(ProductComponent(product_id=tchep.id, article_id=saumon.id, quantity=Decimal(1)))
    now = datetime.now(timezone.utc)

    def mov(day: date, m_type: str, qty: int, order_id: str | None = None,
            item_id: str | None = None) -> None:
        db_session.add(StockMovement(
            article_id=saumon.id, type=m_type, quantity=Decimal(qty), quantity_after=Decimal(0),
            unit_cost_xof=Decimal(500), business_date=day, reference_order_id=order_id,
            reference_order_item_id=item_id, created_at=now,
        ))

    mov(date(2026, 10, 30), "OPENING", 6)
    mov(date(2026, 10, 30), "PURCHASE_IN", 14)

    def day_sales(day: date, catalog: list[int], free: int) -> None:
        session = CashSession(cash_register_id="reg-01", opened_by_user_id="usr-caissier-01",
                              business_date=day, status=CashSessionStatus.CLOSED,
                              opening_float_xof=0)
        db_session.add(session)
        db_session.flush()
        lines = [(q, True) for q in catalog] + [(1, False)] * free
        for n, (qty, linked) in enumerate(lines):
            order = Order(order_number=f"CMD-{day}-{n}", cash_session_id=session.id,
                          opened_by_user_id="usr-caissier-01", status=OrderStatus.PAID,
                          total_ttc_xof=3500 * qty, total_ht_xof=3500 * qty, total_vat_xof=0,
                          paid_xof=3500 * qty, due_xof=0)
            db_session.add(order)
            db_session.flush()
            item = OrderItem(order_id=order.id, product_id=tchep.id if linked else None,
                             product_name_snapshot="Tchep+Saumon", category_snapshot="Plats",
                             unit_price_xof=3500, quantity=qty, line_total_xof=3500 * qty,
                             added_by_user_id="usr-caissier-01")
            db_session.add(item)
            db_session.flush()
            if linked:  # les 2 plats hors menu du lundi n'avaient rien déstocké
                mov(day, "SALE_OUT", -qty, str(order.id), str(item.id))

    day_sales(date(2026, 11, 2), [1, 2, 1, 1, 1, 1], free=2)
    mov(date(2026, 11, 2), "INVENTORY_COUNT", -7)
    day_sales(date(2026, 11, 3), [1, 1, 1, 1], free=0)
    for day, qty in ((date(2026, 11, 2), "6"), (date(2026, 11, 3), "4")):
        db_session.add(DailyPreparation(
            business_date=day, article_id=saumon.id, prepared_quantity=Decimal(qty),
            yield_portions_per_unit=Decimal(1), theoretical_dishes=int(qty),
            user_id="usr-caissier-01", status="ESTIMATED", estimated_quantity=Decimal(qty),
        ))
    db_session.commit()

    matrix = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    row = next(r for r in matrix.rows if r.article_id == str(saumon.id))
    _assert_ledger_identity(row)
    lundi, mardi = row.days[0], row.days[1]

    assert row.opening_stock_qty == 20.0
    assert lundi.sold_dishes == 9
    assert lundi.stock_sold_quantity == 7.0
    assert lundi.non_destocked_dishes == 2
    assert lundi.inventory_variance_quantity == -7.0
    assert lundi.closing_quantity == 6.0
    assert lundi.preparation_gap_quantity == -3.0  # sorti 6 pour 9 plats encaissés
    assert mardi.closing_quantity == 2.0
    assert row.closing_stock_qty == row.current_stock_qty == 2.0
    assert row.total_non_destocked_dishes == 2


def test_semaine_reelle_du_brochet_synthese_et_matrice_coherentes(db_session: Session) -> None:
    """Rejeu de la production (02-05/11/2026) : la synthèse affichait 6 brochets manquants,
    la matrice « +1 » et une marge de 100 %.
    - La synthèse retenait la correction −6 (migration 025) sans l'inventaire +6 qu'elle
      annulait : inventaires et corrections sont désormais compensés → écart 0.
    - L'écart sorti/vendu compare les sorties au besoin des plats encaissés, seulement les
      jours où la sortie est saisie (le jeudi sans sortie ne compte pas).
    - La marge brute se calcule sur le coût de la matière consommée, pas sur les achats de la
      semaine (le brochet avait été acheté le 30/10)."""
    brochet = StockArticle(
        name="Brochet", category="PROTEINE", unit="pièce", out_mode="RECIPE",
        quantity=Decimal(-1), avg_cost_xof=Decimal(800), is_active=True,
    )
    cat = Category(id="cat-bro", name="Plats", kind="DISH")
    foufou = Product(id="p-foufou-bro", category_id="cat-bro", name="Foufou/foutou brochet",
                     short_name="Foufou bro", price_xof=3500, is_active=True)
    db_session.add_all([brochet, cat, foufou])
    db_session.flush()
    db_session.add(ProductComponent(product_id=foufou.id, article_id=brochet.id,
                                    quantity=Decimal(1)))
    now = datetime.now(timezone.utc)

    def mov(day: date, m_type: str, qty: int, order_id: str | None = None,
            item_id: str | None = None) -> None:
        db_session.add(StockMovement(
            article_id=brochet.id, type=m_type, quantity=Decimal(qty), quantity_after=Decimal(0),
            unit_cost_xof=Decimal(800), business_date=day, reference_order_id=order_id,
            reference_order_item_id=item_id, created_at=now,
        ))

    def day_sales(day: date, destocked: int, not_destocked: int = 0) -> None:
        session = CashSession(cash_register_id="reg-01", opened_by_user_id="usr-caissier-01",
                              business_date=day, status=CashSessionStatus.CLOSED,
                              opening_float_xof=0)
        db_session.add(session)
        db_session.flush()
        for n in range(destocked + not_destocked):
            order = Order(order_number=f"BRO-{day}-{n}", cash_session_id=session.id,
                          opened_by_user_id="usr-caissier-01", status=OrderStatus.PAID,
                          total_ttc_xof=3500, total_ht_xof=3500, total_vat_xof=0,
                          paid_xof=3500, due_xof=0)
            db_session.add(order)
            db_session.flush()
            item = OrderItem(order_id=order.id, product_id=foufou.id,
                             product_name_snapshot="Foufou/foutou brochet",
                             category_snapshot="Plats", unit_price_xof=3500, quantity=1,
                             line_total_xof=3500, added_by_user_id="usr-caissier-01")
            db_session.add(item)
            db_session.flush()
            if n < destocked:
                mov(day, "SALE_OUT", -1, str(order.id), str(item.id))

    mov(date(2026, 10, 30), "OPENING", 6)
    mov(date(2026, 10, 30), "PURCHASE_IN", 24)
    day_sales(date(2026, 11, 2), destocked=4, not_destocked=8)
    mov(date(2026, 11, 2), "INVENTORY_COUNT", 6)
    day_sales(date(2026, 11, 3), destocked=11)
    mov(date(2026, 11, 3), "SALE_OUT", -8)  # rattrapage des 8 plats du lundi
    mov(date(2026, 11, 3), "SALE_OUT", -6)  # migration 025, annule l'inventaire du lundi
    day_sales(date(2026, 11, 4), destocked=3)
    day_sales(date(2026, 11, 5), destocked=5)
    for day, qty in ((date(2026, 11, 2), 12), (date(2026, 11, 3), 11), (date(2026, 11, 4), 3)):
        db_session.add(DailyPreparation(
            business_date=day, article_id=brochet.id, prepared_quantity=Decimal(qty),
            yield_portions_per_unit=Decimal(1), theoretical_dishes=qty,
            user_id="usr-caissier-01", status="VALIDATED", estimated_quantity=Decimal(qty),
        ))
    db_session.commit()

    yields = reporting_service.protein_yield_report(db_session, date(2026, 11, 1), date(2026, 11, 30))
    yrow = next(i for i in yields.items if i.article_id == str(brochet.id))
    assert yrow.consumed_quantity == 31.0  # 23 ventes déstockées + 8 de rattrapage
    assert yrow.sold_dishes == 31
    assert yrow.variance_dishes == 0
    assert yrow.status == "NORMAL"

    matrix = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    row = next(r for r in matrix.rows if r.article_id == str(brochet.id))
    _assert_ledger_identity(row)
    assert row.opening_stock_qty == 30.0
    assert row.closing_stock_qty == row.current_stock_qty == -1.0
    assert row.total_sold_dishes == 31
    assert row.dishes_variance == 1  # vendu un brochet de plus que le disponible
    assert [d.preparation_gap_quantity for d in row.days] == [0.0, 0.0, 0.0, 0.0, 0.0]
    assert row.quantity_variance == 0.0  # jeudi, sans sortie saisie, ne compte pas
    assert row.weekly_purchased_cost_xof == 0
    assert row.actual_revenue_xof == 31 * 3500
    assert row.actual_gross_margin_xof == 31 * 3500 - 31 * 800
    assert row.actual_gross_margin_pct < 100
