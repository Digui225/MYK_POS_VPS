from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse import cli
from caisse.domain.enums import UserRole
from caisse.models import CashRegister, Product, RestaurantTable, StockMovement
from caisse.seeds.demo import load_demo_menu

from .conftest import auth, login

pytestmark = pytest.mark.integration


@pytest.fixture
def setup(client: TestClient, db: Session, make_user, make_cash_register) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    load_demo_menu(db)
    db.add(RestaurantTable(label="1", sort_order=0))
    db.commit()
    make_user("111111", UserRole.CAISSIER)
    make_user("222222", UserRole.RESPONSABLE)
    make_user("333333", UserRole.ADMIN)
    register: CashRegister = make_cash_register()
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    admin = auth(login(client, "333333")["access_token"])  # type: ignore[arg-type]
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "open"},
        json={"cash_register_id": str(register.id), "opening_float_xof": 0},
    )
    assert opened.status_code == 201, opened.text
    return {
        "cashier": cashier,
        "manager": manager,
        "admin": admin,
        "business_date": opened.json()["business_date"],
        "products": {p.name: str(p.id) for p in db.scalars(select(Product))},
    }


def _article(client: TestClient, headers: dict[str, str], **body: Any) -> dict[str, Any]:
    payload = {"category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE", **body}
    resp = client.post("/api/v1/stock/articles", headers=headers, json=payload)
    assert resp.status_code == 201, resp.text
    return resp.json()  # type: ignore[no-any-return]


def _post(client: TestClient, headers: dict[str, str], path: str, key: str, body: Any) -> Any:
    return client.post(
        f"/api/v1/stock/{path}", headers={**headers, "Idempotency-Key": key}, json=body
    )


def _beef_dish(client: TestClient, setup: dict[str, Any]) -> tuple[str, str]:
    """Bœuf : 10 kg à 4 000 ; « Brochettes de boeuf » (2 000) consomme 0,2 kg."""
    manager = setup["manager"]
    beef = _article(client, manager, name="Bœuf", avg_cost_xof=4000)
    received = _post(
        client,
        manager,
        "receipts",
        "beef-in",
        {"lines": [{"article_id": beef["id"], "quantity": 10, "total_cost_xof": 40000}]},
    )
    assert received.status_code == 201, received.text
    product_id = setup["products"]["Brochettes de boeuf"]
    resp = client.put(
        f"/api/v1/products/{product_id}/components",
        headers=manager,
        json={"components": [{"article_id": beef["id"], "quantity": 0.2}]},
    )
    assert resp.status_code == 200, resp.text
    return beef["id"], product_id


def _sell(
    client: TestClient, setup: dict[str, Any], lines: dict[str, int], *, pay: int | None = None
) -> tuple[str, dict[str, Any]]:
    """Vente au comptoir ; `pay` : montant encaissé (défaut : tout)."""
    cashier = setup["cashier"]
    order_id = client.post("/api/v1/orders", headers=cashier, json={}).json()["order"]["id"]
    for name, quantity in lines.items():
        resp = client.post(
            f"/api/v1/orders/{order_id}/items",
            headers=cashier,
            json={"product_id": setup["products"][name], "quantity": quantity},
        )
        assert resp.status_code == 201, resp.text
    due = client.get(f"/api/v1/orders/{order_id}", headers=cashier).json()["due_xof"]
    paid = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cashier, "Idempotency-Key": f"pay-{order_id}"},
        json={"method": "CASH", "amount_xof": pay or due},
    )
    assert paid.status_code == 201, paid.text
    return order_id, paid.json()


def _quantity(client: TestClient, setup: dict[str, Any], article_id: str) -> float:
    resp = client.get(f"/api/v1/stock/articles/{article_id}", headers=setup["manager"])
    return resp.json()["quantity"]  # type: ignore[no-any-return]


def test_roles(client: TestClient, setup: dict[str, Any]) -> None:
    assert client.get("/api/v1/stock/articles", headers=setup["cashier"]).status_code == 403
    assert client.get("/api/v1/stock/articles", headers=setup["manager"]).status_code == 200
    assert client.get("/api/v1/reports/sales", headers=setup["manager"]).status_code == 403
    assert client.get("/api/v1/reports/stock", headers=setup["manager"]).status_code == 403
    assert client.get("/api/v1/reports/sales", headers=setup["admin"]).status_code == 200


def test_article_create_update(client: TestClient, setup: dict[str, Any]) -> None:
    manager = setup["manager"]
    beef = _article(client, manager, name="Bœuf", avg_cost_xof=4000, alert_threshold=3)
    assert (beef["quantity"], beef["avg_cost_xof"], beef["value_xof"]) == (0, 4000, 0)
    assert beef["is_low"] is True  # 0 ≤ seuil

    dup = client.post(
        "/api/v1/stock/articles",
        headers=manager,
        json={"name": "BŒUF", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE"},
    )
    assert dup.status_code == 409
    assert dup.json()["code"] == "STOCK_ARTICLE_NAME_EXISTS"
    assert dup.json()["meta"]["article_id"] == beef["id"]

    patched = client.patch(
        f"/api/v1/stock/articles/{beef['id']}",
        headers=manager,
        json={"alert_threshold": None, "unit": "kilo", "name": None},
    )
    assert patched.status_code == 200, patched.text
    body = patched.json()
    assert (body["name"], body["unit"], body["alert_threshold"]) == ("Bœuf", "kilo", None)
    assert body["is_low"] is False

    listed = client.get("/api/v1/stock/articles?category=PROTEINE", headers=manager).json()
    assert [a["name"] for a in listed["items"]] == ["Bœuf"]


def test_movements_page_through_lines_of_one_receipt(
    client: TestClient, setup: dict[str, Any]
) -> None:
    """Les lignes d'une même saisie ont le même horodatage : l'id les départage."""
    url = "/api/v1/stock/movements?type=PURCHASE_IN&limit=2"
    manager = setup["manager"]
    lines = [
        {
            "article_id": _article(client, manager, name=name)["id"],
            "quantity": 1,
            "total_cost_xof": 1000,
        }
        for name in ("Bœuf", "Mouton", "Poulet")
    ]
    assert _post(client, manager, "receipts", "r1", {"lines": lines}).status_code == 201

    first = client.get(url, headers=manager).json()
    assert len(first["items"]) == 2
    rest = client.get(f"{url}&cursor={first['next_cursor']}", headers=manager).json()
    assert len(rest["items"]) == 1
    assert rest["next_cursor"] is None
    ids = {m["id"] for m in first["items"] + rest["items"]}
    assert len(ids) == 3


def test_receipt_weighted_cost_and_idempotency(client: TestClient, setup: dict[str, Any]) -> None:
    manager = setup["manager"]
    beef = _article(client, manager, name="Bœuf")
    first = {"lines": [{"article_id": beef["id"], "quantity": 10, "total_cost_xof": 40000}]}
    created = _post(client, manager, "receipts", "r1", first)
    assert created.status_code == 201, created.text
    assert created.json()["articles"][0]["avg_cost_xof"] == 4000
    assert created.json()["movements"][0]["business_date"] == setup["business_date"]

    replay = _post(client, manager, "receipts", "r1", first)
    assert replay.status_code == 200
    assert replay.headers["Idempotent-Replay"] == "true"
    assert replay.json() == created.json()

    other = {"lines": [{"article_id": beef["id"], "quantity": 5, "unit_cost_xof": 4600}]}
    assert _post(client, manager, "receipts", "r1", other).status_code == 409
    second = _post(client, manager, "receipts", "r2", {"supplier": "M. Yapi", **other})
    assert second.status_code == 201
    article = second.json()["articles"][0]
    assert (article["quantity"], article["avg_cost_xof"], article["value_xof"]) == (
        15,
        4200,
        63000,
    )

    unknown = _post(
        client,
        manager,
        "receipts",
        "r3",
        {"lines": [{"article_id": setup["products"]["Alloco"], "quantity": 1, "unit_cost_xof": 1}]},
    )
    assert unknown.status_code == 404
    both = {"lines": [{"article_id": beef["id"], "quantity": 1}]}
    assert _post(client, manager, "receipts", "r4", both).status_code == 422
    twice = {
        "lines": [
            {"article_id": beef["id"], "quantity": 1, "unit_cost_xof": 1},
            {"article_id": beef["id"], "quantity": 2, "unit_cost_xof": 1},
        ]
    }
    assert _post(client, manager, "receipts", "r5", twice).status_code == 422
    assert client.post(
        "/api/v1/stock/receipts", headers=setup["cashier"], json=first
    ).status_code in (403, 422)


def test_components(client: TestClient, setup: dict[str, Any]) -> None:
    manager = setup["manager"]
    beef_id, product_id = _beef_dish(client, setup)
    recipe = client.get(f"/api/v1/products/{product_id}/components", headers=manager).json()
    assert recipe["components"][0]["article_name"] == "Bœuf"
    assert (recipe["cost_xof"], recipe["margin_xof"], recipe["price_xof"]) == (800, 1200, 2000)

    url = f"/api/v1/products/{product_id}/components"
    dup = {"components": [{"article_id": beef_id, "quantity": 1}] * 2}
    assert client.put(url, headers=manager, json=dup).status_code == 422
    unknown = {"components": [{"article_id": product_id, "quantity": 1}]}
    assert client.put(url, headers=manager, json=unknown).status_code == 404

    menu = client.get("/api/v1/products?search=boeuf", headers=setup["cashier"]).json()["items"]
    assert (menu[0]["track_stock"], menu[0]["stock_quantity"]) == (True, 50)  # 10 kg / 0,2

    cleared = client.put(url, headers=manager, json={"components": []})
    assert cleared.json()["components"] == []
    menu = client.get("/api/v1/products?search=boeuf", headers=setup["cashier"]).json()["items"]
    assert (menu[0]["track_stock"], menu[0]["stock_quantity"]) == (False, None)


def test_sale_deducts_and_void_restores(
    client: TestClient, setup: dict[str, Any], db: Session
) -> None:
    beef_id, _ = _beef_dish(client, setup)
    soda = next(
        a
        for a in client.get("/api/v1/stock/articles", headers=setup["manager"]).json()["items"]
        if a["name"] == "Sucrerie 33cl"
    )
    assert soda["quantity"] == 48  # stock de démonstration

    # paiement partiel : rien ne sort
    order_id, partial = _sell(
        client, setup, {"Brochettes de boeuf": 3, "Sucrerie 33cl": 2, "Alloco": 1}, pay=1000
    )
    assert partial["order"]["status"] == "PARTIALLY_PAID"
    assert _quantity(client, setup, beef_id) == 10

    # solde : 3 x 0,2 kg de bœuf et 2 sucreries ; l'alloco n'a pas de fiche
    rest = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**setup["cashier"], "Idempotency-Key": "rest"},
        json={"method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 7000},
    )
    assert rest.json()["order"]["status"] == "PAID", rest.text
    assert _quantity(client, setup, beef_id) == 9.4
    assert _quantity(client, setup, soda["id"]) == 46
    sales = db.scalars(select(StockMovement).where(StockMovement.type == "SALE_OUT")).all()
    assert len(sales) == 2 and all(str(m.reference_order_id) == order_id for m in sales)

    # annulation du dernier paiement : la commande n'est plus soldée, le stock revient
    payment_id = rest.json()["payment"]["id"]
    voided = client.delete(
        f"/api/v1/orders/{order_id}/payments/{payment_id}?reason=erreur",
        headers=setup["manager"],
    )
    assert voided.status_code == 200, voided.text
    assert _quantity(client, setup, beef_id) == 10
    assert _quantity(client, setup, soda["id"]) == 48

    # nouvel encaissement : une seule sortie de plus
    again = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**setup["cashier"], "Idempotency-Key": "again"},
        json={"method": "CASH", "amount_xof": 7000},
    )
    assert again.json()["order"]["status"] == "PAID"
    assert _quantity(client, setup, beef_id) == 9.4
    journal = client.get(
        f"/api/v1/stock/movements?article_id={beef_id}", headers=setup["manager"]
    ).json()["items"]
    assert [m["type"] for m in journal] == ["SALE_OUT", "RETURN_IN", "SALE_OUT", "PURCHASE_IN"]
    assert journal[0]["value_xof"] == -2400


def test_count_and_loss(client: TestClient, setup: dict[str, Any]) -> None:
    manager = setup["manager"]
    beef_id, _ = _beef_dish(client, setup)
    _sell(client, setup, {"Brochettes de boeuf": 5})  # théorique : 9 kg

    counted = _post(
        client,
        manager,
        "counts",
        "c1",
        {"lines": [{"article_id": beef_id, "counted_quantity": 8.5}], "reason": "pesée"},
    )
    assert counted.status_code == 201, counted.text
    movement = counted.json()["movements"][0]
    assert (movement["type"], movement["quantity"], movement["value_xof"]) == (
        "INVENTORY_COUNT",
        -0.5,
        -2000,
    )
    assert counted.json()["warnings"] == []

    loss = _post(
        client,
        manager,
        "losses",
        "l1",
        {"reason": "avarié", "lines": [{"article_id": beef_id, "quantity": 9}]},
    )
    assert loss.status_code == 201
    body = loss.json()
    assert body["articles"][0]["quantity"] == -0.5
    assert body["warnings"][0]["code"] == "STOCK_NEGATIVE_WARNING"
    no_reason = {"lines": [{"article_id": beef_id, "quantity": 1}]}
    assert _post(client, manager, "losses", "l2", no_reason).status_code == 422

    low = client.get("/api/v1/stock/articles?low_only=true", headers=manager).json()["items"]
    assert [a["id"] for a in low] == [beef_id]


def test_reports(client: TestClient, setup: dict[str, Any]) -> None:
    admin, manager, day = setup["admin"], setup["manager"], setup["business_date"]
    beef_id, product_id = _beef_dish(client, setup)
    _sell(client, setup, {"Brochettes de boeuf": 3, "Alloco": 1})  # 7 000, coût 2 400
    _sell(client, setup, {"Brochettes de boeuf": 2})  # 4 000, coût 1 600
    onion = _article(
        client, manager, name="Oignon", category="EPICERIE", out_mode="INVENTORY", avg_cost_xof=400
    )
    _post(
        client,
        manager,
        "receipts",
        "o1",
        {"lines": [{"article_id": onion["id"], "quantity": 25, "total_cost_xof": 10000}]},
    )
    _post(
        client,
        manager,
        "counts",
        "c1",
        {
            "lines": [
                {"article_id": onion["id"], "counted_quantity": 20},  # 5 kg consommés : 2 000
                {"article_id": beef_id, "counted_quantity": 8.75},  # 0,25 kg manquant : 1 000
            ]
        },
    )

    sales = client.get(f"/api/v1/reports/sales?date_from={day}&date_to={day}", headers=admin).json()
    assert sales["totals"] == {
        "revenue_xof": 11000,
        "orders_count": 2,
        "average_ticket_xof": 5500,
        "recipe_cost_xof": 4000,
        "recipe_margin_xof": 7000,
        "uncosted_revenue_xof": 1000,
        "inventory_consumption_xof": 2000,
        "stock_variance_xof": 1000,
        "gross_margin_xof": 4000,
    }
    brochettes = sales["by_product"][0]
    assert (brochettes["product_id"], brochettes["quantity"], brochettes["has_recipe"]) == (
        product_id,
        5,
        True,
    )
    assert brochettes["recipe_margin_xof"] == 6000
    assert sales["by_day"] == [
        {
            "business_date": day,
            "orders_count": 2,
            "revenue_xof": 11000,
            "recipe_cost_xof": 4000,
            "recipe_margin_xof": 7000,
        }
    ]
    assert sales["by_payment_method"] == [{"method": "CASH", "count": 2, "amount_xof": 11000}]
    assert sales["cash_sessions"][0]["status"] == "OPEN"

    stock = client.get("/api/v1/reports/stock", headers=admin).json()  # défaut : la journée
    rows = {a["name"]: a for a in stock["articles"]}
    beef = rows["Bœuf"]
    assert (beef["opening_quantity"], beef["purchased_quantity"], beef["sold_quantity"]) == (
        0,
        10,
        1,
    )
    assert (beef["count_adjustment_quantity"], beef["closing_quantity"]) == (-0.25, 8.75)
    assert (beef["consumption_quantity"], beef["consumption_xof"]) == (1.25, 5000)
    assert rows["Oignon"]["consumption_xof"] == 2000
    assert stock["totals"]["purchases_xof"] == 50000
    assert stock["totals"]["sales_cost_xof"] == 4000
    assert stock["totals"]["inventory_consumption_xof"] == 2000
    assert stock["totals"]["stock_variance_xof"] == 1000

    # la journée précédente ne voit rien de tout ça
    past = client.get(
        "/api/v1/reports/stock?date_from=2020-01-01&date_to=2020-01-01", headers=admin
    ).json()
    beef_then = next(a for a in past["articles"] if a["name"] == "Bœuf")
    assert (beef_then["closing_quantity"], beef_then["purchased_quantity"]) == (0, 0)

    bad = client.get("/api/v1/reports/sales?date_from=2026-02-01&date_to=2026-01-01", headers=admin)
    assert bad.status_code == 422


def test_import_real_menu_and_stock(client: TestClient, make_user, capsys) -> None:  # type: ignore[no-untyped-def]
    """Les CSV de seeds/data (tirés des Excel) s'importent sur une base vide."""
    make_user("111111", UserRole.CAISSIER)
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    cli.main(["import-catalog"])
    cli.main(["import-stock", "--stock-initial"])
    out = capsys.readouterr().out
    assert "40 produit(s) importé(s)." in out
    assert "Articles : 115 créé(s), 0 déjà présent(s)" in out
    assert "stock de départ : 23 article(s)" in out
    assert "fiches techniques : 35 produit(s)" in out

    cli.main(["import-stock"])  # idempotent
    assert "Articles : 0 créé(s), 115 déjà présent(s)" in capsys.readouterr().out

    menu = client.get("/api/v1/products?search=mouton", headers=cashier).json()["items"]
    plate = next(p for p in menu if p["name"] == "Plat mouton")
    assert (plate["short_name"], plate["price_xof"]) == ("Plat mouton", 4000)
    assert (plate["track_stock"], plate["stock_quantity"]) == (True, 29)  # 8 kg / 0,27
    tea = client.get("/api/v1/products?search=th", headers=cashier).json()["items"]
    assert next(p for p in tea if p["name"] == "Thé")["track_stock"] is False
    categories = [
        c["name"] for c in client.get("/api/v1/categories", headers=cashier).json()["items"]
    ]
    assert categories[:3] == ["Viandes", "Poissons", "Foufou / foutou"]


def test_first_count_is_opening_stock(client: TestClient, setup: dict[str, Any]) -> None:
    """Le stock de départ n'est pas un écart : il ne fausse ni la marge ni le rapport."""
    manager, admin = setup["manager"], setup["admin"]
    gas = _article(
        client,
        manager,
        name="Gaz",
        category="ENERGIE",
        unit="bouteille",
        out_mode="INVENTORY",
        avg_cost_xof=14500,
    )
    first = _post(
        client,
        manager,
        "counts",
        "g1",
        {"lines": [{"article_id": gas["id"], "counted_quantity": 3}]},
    )
    assert first.json()["movements"][0]["type"] == "OPENING"
    second = _post(
        client,
        manager,
        "counts",
        "g2",
        {"lines": [{"article_id": gas["id"], "counted_quantity": 2}]},
    )
    assert second.json()["movements"][0]["type"] == "INVENTORY_COUNT"

    totals = client.get("/api/v1/reports/sales", headers=admin).json()["totals"]
    # démo : 5 boissons en stock de départ, sans effet ; gaz : 1 bouteille consommée
    assert (totals["inventory_consumption_xof"], totals["stock_variance_xof"]) == (14500, 0)
    gas_row = next(
        a
        for a in client.get("/api/v1/reports/stock", headers=admin).json()["articles"]
        if a["name"] == "Gaz"
    )
    assert (gas_row["opening_quantity"], gas_row["closing_quantity"]) == (3, 2)
    assert (gas_row["consumption_quantity"], gas_row["count_adjustment_quantity"]) == (1, -1)


def test_payment_warns_on_negative_stock(client: TestClient, setup: dict[str, Any]) -> None:
    """La vente n'est jamais bloquée : le paiement signale l'article passé sous zéro."""
    beef_id, _ = _beef_dish(client, setup)  # 10 kg : 50 portions
    _, paid = _sell(client, setup, {"Brochettes de boeuf": 51})
    assert paid["order"]["status"] == "PAID"
    assert [
        (w["code"], w["meta"]["article_id"], w["meta"]["quantity"]) for w in paid["warnings"]
    ] == [("STOCK_NEGATIVE_WARNING", beef_id, -0.2)]
    _, fine = _sell(client, setup, {"Sucrerie 33cl": 1})
    assert fine["warnings"] == []


def test_yield_report_counts_missing_dishes(client: TestClient, setup: dict[str, Any]) -> None:
    """Le « rapport bœuf » : 2,4 kg consommés auraient dû donner 11,2 plats ; 7 vendus."""
    manager, admin = setup["manager"], setup["admin"]
    beef_id, _ = _beef_dish(client, setup)
    chicken = setup["products"]["Poulet braisé"]  # 2e plat au bœuf, autre prix et portion
    resp = client.put(
        f"/api/v1/products/{chicken}/components",
        headers=manager,
        json={"components": [{"article_id": beef_id, "quantity": 0.25}]},
    )
    assert resp.status_code == 200, resp.text
    _sell(client, setup, {"Brochettes de boeuf": 5, "Poulet braisé": 2, "Jus de bissap": 1})
    lost = _post(
        client,
        manager,
        "losses",
        "l1",
        {"reason": "avarié", "lines": [{"article_id": beef_id, "quantity": 0.3}]},
    )
    assert lost.status_code == 201, lost.text
    counted = _post(
        client,
        manager,
        "counts",
        "c1",
        {"lines": [{"article_id": beef_id, "counted_quantity": 7.6}]},
    )
    assert counted.status_code == 201, counted.text

    assert client.get("/api/v1/reports/yield", headers=manager).status_code == 403
    report = client.get("/api/v1/reports/yield", headers=admin).json()
    beef = report["articles"][0]
    assert beef["name"] == "Bœuf"
    assert beef["counted_in_period"] is True
    assert (beef["opening_quantity"], beef["purchased_quantity"], beef["closing_quantity"]) == (
        0,
        10,
        7.6,
    )
    assert (beef["consumed_quantity"], beef["portion_quantity"]) == (2.4, 0.21)
    assert (beef["expected_portions"], beef["sold_portions"], beef["portion_variance"]) == (
        11.2,
        7,
        4.2,
    )
    assert (beef["loss_portions"], beef["unexplained_portions"]) == (1.4, 2.8)
    # prix moyen pondéré : (5 x 2 000 + 2 x 4 000) / 7
    assert (beef["sold_xof"], beef["average_price_xof"]) == (18000, 2571)
    assert (beef["variance_xof"], beef["unexplained_xof"]) == (10800, 7200)
    assert [(p["name"], p["quantity"], p["portion_quantity"]) for p in beef["products"]] == [
        ("Brochettes de boeuf", 5, 0.2),
        ("Poulet braisé", 2, 0.25),
    ]

    bissap = next(a for a in report["articles"] if a["name"] == "Jus de bissap")
    assert (bissap["counted_in_period"], bissap["sold_portions"]) == (False, 1)
    assert bissap["portion_variance"] == 0  # pas d'inventaire : aucun écart mesurable
    assert report["totals"]["articles_counted"] == 1
    assert report["totals"]["variance_xof"] == 10800
