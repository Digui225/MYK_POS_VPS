from decimal import Decimal
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

