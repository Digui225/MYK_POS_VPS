from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product


def test_complete_stock_and_recipe_workflow(client: TestClient, db_session: Session) -> None:
    # 1. Login responsable & caissier
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    caissier_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    assert caissier_login.status_code == 200
    caissier_token = caissier_login.json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}

    # 2. Créer un article de stock (ex: Filet de bœuf, en kg, out_mode=RECIPE)
    art_res = client.post(
        "/api/v1/stock/articles",
        headers=resp_headers,
        json={
            "name": "Filet de bœuf",
            "category": "PROTEINE",
            "unit": "kg",
            "out_mode": "RECIPE",
            "avg_cost_xof": 4000,
            "alert_threshold": 5.0,
        },
    )
    assert art_res.status_code == 201, art_res.text
    beef = art_res.json()
    beef_id = beef["id"]
    assert beef["quantity"] == 0.0

    # 3. Ouvrir une session de caisse pour la journée comptable 2026-09-28
    sess_res = client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-stock-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 10000, "business_date": "2026-09-28"},
    )
    assert sess_res.status_code == 201, sess_res.text

    # 4. Réception de stock (achat de 20 kg à 4 000 XOF/kg = 80 000 XOF)
    rec_res = client.post(
        "/api/v1/stock/receipts",
        headers={**resp_headers, "Idempotency-Key": "rec-beef-01"},
        json={
            "supplier": "Boucherie Centrale",
            "lines": [
                {
                    "article_id": beef_id,
                    "quantity": 20.0,
                    "total_cost_xof": 80000,
                }
            ],
        },
    )
    assert rec_res.status_code == 201, rec_res.text
    assert rec_res.json()["articles"][0]["quantity"] == 20.0

    # 5. Créer un plat au menu (Steak Frites)
    cat = Category(id="cat-plats-01", name="Plats", kind="DISH")
    dish = Product(
        id="prod-steak-01",
        category_id="cat-plats-01",
        name="Steak Frites",
        short_name="STEAK",
        price_xof=6000,
        is_active=True,
    )
    db_session.add_all([cat, dish])
    db_session.commit()

    # 6. Définir la fiche technique : 1 portion de Steak Frites consomme 0.3 kg de boeuf
    recipe_res = client.put(
        f"/api/v1/products/{dish.id}/components",
        headers=resp_headers,
        json={
            "components": [
                {"article_id": beef_id, "quantity": 0.3}
            ]
        },
    )
    assert recipe_res.status_code == 200, recipe_res.text
    recipe_data = recipe_res.json()
    assert len(recipe_data["components"]) == 1
    assert recipe_data["components"][0]["quantity"] == 0.3
    assert isinstance(recipe_data["cost_xof"], int)
    assert isinstance(recipe_data["margin_xof"], int)
    assert isinstance(recipe_data["components"][0]["cost_xof"], int)
    assert isinstance(recipe_data["components"][0]["unit_cost_xof"], (float, int))

    # Vérifier que le catalogue calcule les portions disponibles (20 kg / 0.3 = 66 portions)
    cat_prods = client.get("/api/v1/catalog/products", headers=resp_headers).json()
    steak_in_cat = [p for p in cat_prods if p["id"] == dish.id][0]
    assert steak_in_cat["track_stock"] is True
    assert steak_in_cat["stock_quantity"] == 66.0

    # 7. Créer une commande de 2 Steaks
    order_res = client.post(
        "/api/v1/orders",
        headers=caissier_headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    )
    order_id = order_res.json()["id"]

    client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=caissier_headers,
        json={"product_id": dish.id, "quantity": 2},
    )

    # 8. Encaisser la commande (12 000 XOF)
    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caissier_headers, "Idempotency-Key": f"pay-stock-{order_id}"},
        json={"method": "CASH", "amount_xof": 12000, "tendered_xof": 12000},
    )
    assert pay_res.status_code == 201, pay_res.text

    # 9. Vérifier le stock après vente : 20.0 - (2 * 0.3) = 19.4 kg
    beef_after = client.get(f"/api/v1/stock/articles/{beef_id}", headers=resp_headers).json()
    assert beef_after["quantity"] == 19.4

    # 10. Déclarer une perte de 0.4 kg
    loss_res = client.post(
        "/api/v1/stock/losses",
        headers={**resp_headers, "Idempotency-Key": "loss-beef-01"},
        json={
            "reason": "Morceau avarié",
            "lines": [
                {
                    "article_id": beef_id,
                    "quantity": 0.4,
                }
            ],
        },
    )
    assert loss_res.status_code == 201, loss_res.text
    assert loss_res.json()["articles"][0]["quantity"] == 19.0

    # 11. Ajustement d'inventaire : compté 18.5 kg (écart de -0.5 kg)
    count_res = client.post(
        "/api/v1/stock/counts",
        headers={**resp_headers, "Idempotency-Key": "count-beef-01"},
        json={
            "lines": [
                {
                    "article_id": beef_id,
                    "counted_quantity": 18.5,
                }
            ]
        },
    )
    assert count_res.status_code == 201, count_res.text
    assert count_res.json()["articles"][0]["quantity"] == 18.5

    # 12. Consulter le journal des mouvements
    mov_res = client.get(f"/api/v1/stock/movements?article_id={beef_id}", headers=resp_headers)
    assert mov_res.status_code == 200
    movements = mov_res.json()["items"]
    # 4 mouvements attendus : PURCHASE_IN (+20), SALE_OUT (-0.6), LOSS_OUT (-0.4), INVENTORY_COUNT (-0.5)
    assert len(movements) == 4

    # 13. Vérifier les rapports de vente et de stock
    sales_rep = client.get("/api/v1/reports/sales?date_from=2026-09-28&date_to=2026-09-28", headers=resp_headers)
    assert sales_rep.status_code == 200, sales_rep.text
    sales_data = sales_rep.json()
    assert sales_data["totals"]["revenue_xof"] == 12000
    assert sales_data["totals"]["orders_count"] == 1

    stock_rep = client.get("/api/v1/reports/stock?date_from=2026-09-28&date_to=2026-09-28", headers=resp_headers)
    assert stock_rep.status_code == 200, stock_rep.text
    stock_data = stock_rep.json()
    assert len(stock_data["articles"]) >= 1
    beef_row = [a for a in stock_data["articles"] if a["article_id"] == beef_id][0]
    assert beef_row["closing_quantity"] == 18.5
    assert beef_row["purchased_quantity"] == 20.0
    assert beef_row["sold_quantity"] == 0.6
    assert beef_row["loss_quantity"] == 0.4
    assert beef_row["count_adjustment_quantity"] == -0.5


def test_stock_idempotency_and_name_conflict(client: TestClient, db_session: Session) -> None:
    resp_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    # 1. Créer article
    art = client.post(
        "/api/v1/stock/articles",
        headers=headers,
        json={"name": "Poulet Frais", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE"},
    ).json()

    # Tentative doublon nom -> 409
    dup = client.post(
        "/api/v1/stock/articles",
        headers=headers,
        json={"name": "Poulet Frais", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE"},
    )
    assert dup.status_code == 409

    # 2. Idempotence sur réception
    rec1 = client.post(
        "/api/v1/stock/receipts",
        headers={**headers, "Idempotency-Key": "rec-poulet-unique"},
        json={"lines": [{"article_id": art["id"], "quantity": 10.0, "total_cost_xof": 25000}]},
    )
    assert rec1.status_code == 201

    rec2 = client.post(
        "/api/v1/stock/receipts",
        headers={**headers, "Idempotency-Key": "rec-poulet-unique"},
        json={"lines": [{"article_id": art["id"], "quantity": 10.0, "total_cost_xof": 25000}]},
    )
    assert rec2.status_code == 200
    assert rec2.json()["articles"][0]["quantity"] == 10.0

    # Vérifier que le stock n'a été crédité qu'une seule fois
    art_after = client.get(f"/api/v1/stock/articles/{art['id']}", headers=headers).json()
    assert art_after["quantity"] == 10.0


def test_brochet_reconciliation_to_7_without_touching_saumon(
    client: TestClient, db_session: Session
) -> None:
    """Vérifie que la migration 024 ramène Brochet de 21 à 7 sans altérer le stock de départ (30)
    dans la Matrice de Contrôle ni toucher au Saumon (2), et que le filet de sécurité Brochet déstocke."""
    import importlib.util
    from datetime import date, datetime, timezone
    from decimal import Decimal
    from pathlib import Path
    from unittest.mock import patch

    from caisse.models.production import DailyPreparation
    from caisse.models.stock import ProductComponent, StockArticle, StockMovement
    from caisse.models.user import User
    from caisse.services.production_service import get_weekly_matrix

    resp_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    caissier_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}

    admin_user = db_session.query(User).first()
    assert admin_user is not None

    # 1. Créer Brochet (21 pièces après -9 de ventes sur un départ de 30) et Saumon (2 morceaux)
    brochet = StockArticle(
        id="art-brochet-01",
        name="Brochet",
        category="PROTEINE",
        unit="pièce",
        out_mode="RECIPE",
        quantity=Decimal("21.000"),
        avg_cost_xof=Decimal("800.00"),
        is_active=True,
    )
    saumon = StockArticle(
        id="art-saumon-01",
        name="Saumon",
        category="PROTEINE",
        unit="morceau",
        out_mode="RECIPE",
        quantity=Decimal("2.000"),
        avg_cost_xof=Decimal("500.00"),
        is_active=True,
    )
    cat = Category(id="cat-sauces-bro", name="Sauces", kind="FOOD")
    prod_unlinked = Product(
        id="prod-sce-bro",
        category_id="cat-sauces-bro",
        name="Sauce Feuille + Brochet",
        short_name="Sce Feuille+Brochet",
        price_xof=3500,
        is_custom=False,
        is_active=True,
    )
    db_session.add_all([brochet, saumon, cat, prod_unlinked])
    db_session.flush()

    now_utc = datetime.now(timezone.utc)
    db_session.add_all(
        [
            StockMovement(
                id="mov-bro-open",
                article_id=brochet.id,
                type="OPENING",
                quantity=Decimal("30.000"),
                quantity_after=Decimal("30.000"),
                unit_cost_xof=Decimal("800.00"),
                business_date=date(2026, 11, 2),
                created_at=now_utc,
            ),
            StockMovement(
                id="mov-bro-sale9",
                article_id=brochet.id,
                type="SALE_OUT",
                quantity=Decimal("-9.000"),
                quantity_after=Decimal("21.000"),
                unit_cost_xof=Decimal("800.00"),
                business_date=date(2026, 11, 3),
                created_at=now_utc,
            ),
            DailyPreparation(
                id="prep-bro-mon",
                business_date=date(2026, 11, 2),
                article_id=brochet.id,
                prepared_quantity=Decimal("12.000"),
                yield_portions_per_unit=Decimal("1.00"),
                theoretical_dishes=12,
                user_id=admin_user.id,
                notes="Auto-validé à la clôture de caisse",
            ),
            DailyPreparation(
                id="prep-bro-tue",
                business_date=date(2026, 11, 3),
                article_id=brochet.id,
                prepared_quantity=Decimal("11.000"),
                yield_portions_per_unit=Decimal("1.00"),
                theoretical_dishes=11,
                user_id=admin_user.id,
                notes="Auto-validé à la clôture de caisse",
            ),
        ]
    )
    db_session.commit()

    # 2. Exécuter la migration 024 sur la connexion active
    mig_path = (
        Path(__file__).resolve().parents[2]
        / "alembic"
        / "versions"
        / "024_fix_brochet_stock.py"
    )
    spec = importlib.util.spec_from_file_location("mig_024", mig_path)
    assert spec and spec.loader
    mig_024 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mig_024)

    conn = db_session.connection()
    with patch.object(mig_024.op, "get_bind", return_value=conn), patch.object(
        mig_024.op,
        "bulk_insert",
        side_effect=lambda tbl, rows: conn.execute(tbl.insert(), rows) if rows else None,
    ):
        mig_024.upgrade()
        # Vérifier l'idempotence (un 2e passage ne déduit rien de plus)
        mig_024.upgrade()
    db_session.commit()
    db_session.expire_all()

    # 3. Vérifications : Brochet est passé à 7, Saumon reste intact à 2, fiche recette créée
    brochet_out = client.get(f"/api/v1/stock/articles/{brochet.id}", headers=resp_headers).json()
    saumon_out = client.get(f"/api/v1/stock/articles/{saumon.id}", headers=resp_headers).json()
    assert brochet_out["quantity"] == 7.0
    assert saumon_out["quantity"] == 2.0

    linked_comp = (
        db_session.query(ProductComponent)
        .filter(
            ProductComponent.product_id == prod_unlinked.id,
            ProductComponent.article_id == brochet.id,
        )
        .first()
    )
    assert linked_comp is not None
    assert float(linked_comp.quantity) == 1.0

    # La Matrice de Contrôle conserve bien 30 au départ et 7 restant mercredi
    matrix = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    brochet_matrix_row = [r for r in matrix.rows if r.article_id == brochet.id][0]
    assert brochet_matrix_row.opening_stock_qty == 30.0
    assert brochet_matrix_row.days[2].remaining_quantity == 7.0

    # 4. Vérifier qu'une vente future en Plat libre Brochet décrémente Brochet (7 -> 6) sans toucher Saumon
    client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-bro-024"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 5000, "business_date": "2026-11-04"},
    )
    order_res = client.post(
        "/api/v1/orders",
        headers=caissier_headers,
        json={"table_id": "tbl-01", "guests_count": 1},
    )
    oid = order_res.json()["id"]
    client.post(
        f"/api/v1/orders/{oid}/items",
        headers=caissier_headers,
        json={"custom_name": "Foufou brochet", "unit_price_xof": 3500, "quantity": 1},
    )
    client.post(
        f"/api/v1/orders/{oid}/items",
        headers=caissier_headers,
        json={"custom_name": "Foutou saumon", "unit_price_xof": 3500, "quantity": 1},
    )
    pay_res = client.post(
        f"/api/v1/orders/{oid}/payments",
        headers={**caissier_headers, "Idempotency-Key": f"pay-bro-{oid}"},
        json={"method": "CASH", "amount_xof": 7000, "tendered_xof": 7000},
    )
    assert pay_res.status_code == 201

    assert client.get(f"/api/v1/stock/articles/{brochet.id}", headers=resp_headers).json()["quantity"] == 6.0
    assert client.get(f"/api/v1/stock/articles/{saumon.id}", headers=resp_headers).json()["quantity"] == 1.0


def test_sync_all_proteins_migration_025_and_freehand_sales(
    client: TestClient, db_session: Session
) -> None:
    """Vérifie que la migration 025 aligne toutes les protéines (Brochet 13->7, Bœuf 7.2->7,
    Loss 15->13, Sosso 14->12, Mouton 5.424->5.43, Poulet 0.25) sur la Matrice sans toucher
    Saumon (2), et que les ventes Hors Menu futures déstockent bien les 9 protéines."""
    import importlib.util
    from datetime import date, datetime, timezone
    from decimal import Decimal
    from pathlib import Path
    from unittest.mock import patch

    from caisse.models.production import DailyPreparation, MarketPurchaseItem, MarketPurchaseList
    from caisse.models.stock import StockArticle, StockMovement
    from caisse.models.user import User
    from caisse.services.production_service import (
        get_market_purchase_protein_analysis,
        get_weekly_matrix,
    )

    resp_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    caissier_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}

    admin_user = db_session.query(User).first()
    assert admin_user is not None
    now_utc = datetime.now(timezone.utc)

    # 1. État réel observé en production avant 025 :
    #    - Brochet : stock 13, mouvements net -17 -> départ 30, sortis 23 -> cible 7
    #    - Bœuf    : stock 7.2, mouvements net +3.8 (+10 achat - 6.2 ventes) -> départ 3.4 + 10 = 13.4, sortis 6.4 -> cible 7
    #    - Loss    : stock 15, mouvements net -3 -> départ 18, sortis 5 -> cible 13
    #    - Mouton  : stock 5.424, mouvements net -4.576 -> départ 10, sortis 4.57 -> cible 5.43
    #    - Poulet  : stock 0.25, mouvements net -11.75 -> départ 12, sortis 11.75 -> cible 0.25
    #    - Saumon  : stock 2.0, mouvements net -18 (-11 ventes - 7 inventaire) -> départ 20, sortis 10 -> DOIT RESTER 2.0
    #    - Sosso   : stock 14, mouvements net +1 (+5 achat - 4 ventes) -> départ 13 + 5 = 18, sortis 6 -> cible 12
    articles = [
        StockArticle(id="p025-brochet", name="Brochet", category="PROTEINE", unit="pièce", out_mode="RECIPE", quantity=Decimal("13.000"), avg_cost_xof=Decimal("800.00"), is_active=True),
        StockArticle(id="p025-boeuf", name="Bœuf", category="PROTEINE", unit="kg", out_mode="RECIPE", quantity=Decimal("7.200"), avg_cost_xof=Decimal("4000.00"), is_active=True),
        StockArticle(id="p025-loss", name="Loss", category="PROTEINE", unit="pièce", out_mode="RECIPE", quantity=Decimal("15.000"), avg_cost_xof=Decimal("556.00"), is_active=True),
        StockArticle(id="p025-mouton", name="Mouton", category="PROTEINE", unit="kg", out_mode="RECIPE", quantity=Decimal("5.424"), avg_cost_xof=Decimal("6000.00"), is_active=True),
        StockArticle(id="p025-poulet", name="Poulet", category="PROTEINE", unit="pièce", out_mode="RECIPE", quantity=Decimal("0.250"), avg_cost_xof=Decimal("3000.00"), is_active=True),
        StockArticle(id="p025-saumon", name="Saumon", category="PROTEINE", unit="morceau", out_mode="RECIPE", quantity=Decimal("2.000"), avg_cost_xof=Decimal("500.00"), is_active=True),
        StockArticle(id="p025-sosso", name="Sosso", category="PROTEINE", unit="pièce", out_mode="RECIPE", quantity=Decimal("14.000"), avg_cost_xof=Decimal("1540.00"), is_active=True),
    ]
    db_session.add_all(articles)
    db_session.flush()

    mp = MarketPurchaseList(
        id="mp-025-completed",
        business_date=date(2026, 11, 2),
        total_budget_xof=47700,
        status="COMPLETED",
        created_by_user_id=admin_user.id,
        validated_by_user_id=admin_user.id,
    )
    mp_draft = MarketPurchaseList(
        id="mp-025-draft",
        business_date=date(2026, 11, 3),
        total_budget_xof=45000,
        status="DRAFT",
        created_by_user_id=admin_user.id,
    )
    db_session.add_all([mp, mp_draft])
    db_session.flush()

    db_session.add_all(
        [
            MarketPurchaseItem(id="mpi-boeuf", purchase_list_id=mp.id, article_id="p025-boeuf", quantity=Decimal("10.000"), unit_price_xof=4000, total_price_xof=40000),
            MarketPurchaseItem(id="mpi-sosso", purchase_list_id=mp.id, article_id="p025-sosso", quantity=Decimal("5.000"), unit_price_xof=1540, total_price_xof=7700),
            MarketPurchaseItem(id="mpi-draft-poulet", purchase_list_id=mp_draft.id, article_id="p025-poulet", quantity=Decimal("15.000"), unit_price_xof=3000, total_price_xof=45000),
            StockMovement(id="m025-bro", article_id="p025-brochet", type="SALE_OUT", quantity=Decimal("-17.000"), quantity_after=Decimal("13.000"), unit_cost_xof=Decimal("800"), business_date=date(2026, 11, 3), created_at=now_utc),
            StockMovement(id="m025-boeuf-in", article_id="p025-boeuf", type="PURCHASE_IN", quantity=Decimal("10.000"), quantity_after=Decimal("13.400"), unit_cost_xof=Decimal("4000"), business_date=date(2026, 11, 2), created_at=now_utc),
            StockMovement(id="m025-boeuf-out", article_id="p025-boeuf", type="SALE_OUT", quantity=Decimal("-6.200"), quantity_after=Decimal("7.200"), unit_cost_xof=Decimal("4000"), business_date=date(2026, 11, 3), created_at=now_utc),
            StockMovement(id="m025-loss", article_id="p025-loss", type="SALE_OUT", quantity=Decimal("-3.000"), quantity_after=Decimal("15.000"), unit_cost_xof=Decimal("556"), business_date=date(2026, 11, 3), created_at=now_utc),
            StockMovement(id="m025-mouton", article_id="p025-mouton", type="SALE_OUT", quantity=Decimal("-4.576"), quantity_after=Decimal("5.424"), unit_cost_xof=Decimal("6000"), business_date=date(2026, 11, 3), created_at=now_utc),
            StockMovement(id="m025-poulet", article_id="p025-poulet", type="SALE_OUT", quantity=Decimal("-11.750"), quantity_after=Decimal("0.250"), unit_cost_xof=Decimal("3000"), business_date=date(2026, 11, 3), created_at=now_utc),
            StockMovement(id="m025-saumon-inv", article_id="p025-saumon", type="INVENTORY_COUNT", quantity=Decimal("-18.000"), quantity_after=Decimal("2.000"), unit_cost_xof=Decimal("500"), business_date=date(2026, 11, 2), created_at=now_utc),
            StockMovement(id="m025-sosso-in", article_id="p025-sosso", type="PURCHASE_IN", quantity=Decimal("5.000"), quantity_after=Decimal("18.000"), unit_cost_xof=Decimal("1540"), business_date=date(2026, 11, 2), created_at=now_utc),
            StockMovement(id="m025-sosso-out", article_id="p025-sosso", type="SALE_OUT", quantity=Decimal("-4.000"), quantity_after=Decimal("14.000"), unit_cost_xof=Decimal("1540"), business_date=date(2026, 11, 3), created_at=now_utc),
            DailyPreparation(id="dp025-bro", business_date=date(2026, 11, 2), article_id="p025-brochet", prepared_quantity=Decimal("23.000"), yield_portions_per_unit=Decimal("1.00"), theoretical_dishes=23, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-boeuf", business_date=date(2026, 11, 2), article_id="p025-boeuf", prepared_quantity=Decimal("6.400"), yield_portions_per_unit=Decimal("5.00"), theoretical_dishes=32, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-loss", business_date=date(2026, 11, 2), article_id="p025-loss", prepared_quantity=Decimal("5.000"), yield_portions_per_unit=Decimal("1.00"), theoretical_dishes=5, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-mouton", business_date=date(2026, 11, 2), article_id="p025-mouton", prepared_quantity=Decimal("4.570"), yield_portions_per_unit=Decimal("3.50"), theoretical_dishes=16, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-poulet", business_date=date(2026, 11, 2), article_id="p025-poulet", prepared_quantity=Decimal("11.750"), yield_portions_per_unit=Decimal("4.00"), theoretical_dishes=47, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-saumon", business_date=date(2026, 11, 2), article_id="p025-saumon", prepared_quantity=Decimal("10.000"), yield_portions_per_unit=Decimal("1.00"), theoretical_dishes=10, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
            DailyPreparation(id="dp025-sosso", business_date=date(2026, 11, 2), article_id="p025-sosso", prepared_quantity=Decimal("6.000"), yield_portions_per_unit=Decimal("1.00"), theoretical_dishes=6, user_id=admin_user.id, notes="Auto-validé à la clôture de caisse"),
        ]
    )
    db_session.commit()

    # 2. Exécuter la migration 025 (et vérifier qu'un 2e passage est idempotent)
    mig_path = (
        Path(__file__).resolve().parents[2]
        / "alembic"
        / "versions"
        / "025_sync_protein_stock.py"
    )
    spec = importlib.util.spec_from_file_location("mig_025", mig_path)
    assert spec and spec.loader
    mig_025 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mig_025)

    conn = db_session.connection()
    with patch.object(mig_025.op, "get_bind", return_value=conn), patch.object(
        mig_025.op,
        "bulk_insert",
        side_effect=lambda tbl, rows: conn.execute(tbl.insert(), rows) if rows else None,
    ):
        mig_025.upgrade()
        mig_025.upgrade()
    db_session.commit()
    db_session.expire_all()

    # 3. Vérifier l'alignement exact entre Bon d'achat, Stock et Matrice (Saumon restant à 2)
    analysis = get_market_purchase_protein_analysis(db_session, mp_draft.id)
    by_name = {p.article_name: p for p in analysis.proteins}
    assert by_name["Brochet"].estimated_remaining_quantity == 7.0
    assert by_name["Bœuf"].estimated_remaining_quantity == 7.0
    assert by_name["Loss"].estimated_remaining_quantity == 13.0
    assert by_name["Mouton"].estimated_remaining_quantity == 5.43
    assert by_name["Poulet"].estimated_remaining_quantity == 0.25
    assert by_name["Poulet"].recommended_quantity == 14.75
    assert by_name["Saumon"].estimated_remaining_quantity == 2.0
    assert by_name["Sosso"].estimated_remaining_quantity == 12.0

    matrix = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    m_by_name = {r.article_name: r for r in matrix.rows}
    assert m_by_name["Brochet"].total_available_qty == 30.0
    assert m_by_name["Bœuf"].total_available_qty == 13.4
    assert m_by_name["Loss"].total_available_qty == 18.0
    assert m_by_name["Mouton"].total_available_qty == 10.0
    assert m_by_name["Poulet"].total_available_qty == 12.0
    assert m_by_name["Sosso"].total_available_qty == 18.0

    # 4. Vérifier que les ventes futures en saisie libre (« Hors Menu ») déstockent bien Sosso, Loss et Bœuf
    client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-025"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 5000, "business_date": "2026-11-04"},
    )
    order_res = client.post(
        "/api/v1/orders",
        headers=caissier_headers,
        json={"table_id": "tbl-01", "guests_count": 3},
    )
    oid = order_res.json()["id"]
    client.post(
        f"/api/v1/orders/{oid}/items",
        headers=caissier_headers,
        json={"custom_name": "Riz dah+ Sosso", "unit_price_xof": 4000, "quantity": 1},
    )
    client.post(
        f"/api/v1/orders/{oid}/items",
        headers=caissier_headers,
        json={"custom_name": "Attiéké + Loss", "unit_price_xof": 3500, "quantity": 1},
    )
    client.post(
        f"/api/v1/orders/{oid}/items",
        headers=caissier_headers,
        json={"custom_name": "Placali + Boeuf", "unit_price_xof": 3000, "quantity": 1},
    )
    pay_res = client.post(
        f"/api/v1/orders/{oid}/payments",
        headers={**caissier_headers, "Idempotency-Key": f"pay-025-{oid}"},
        json={"method": "CASH", "amount_xof": 10500, "tendered_xof": 10500},
    )
    assert pay_res.status_code == 201

    assert client.get("/api/v1/stock/articles/p025-sosso", headers=resp_headers).json()["quantity"] == 11.0
    assert client.get("/api/v1/stock/articles/p025-loss", headers=resp_headers).json()["quantity"] == 12.0
    assert client.get("/api/v1/stock/articles/p025-boeuf", headers=resp_headers).json()["quantity"] == 6.8



