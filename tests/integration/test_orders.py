from decimal import Decimal
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.domain.enums import UserRole
from caisse.models import CashRegister, Category, Product, RestaurantTable
from caisse.seeds.demo import load_demo_menu

from .conftest import auth, login

pytestmark = pytest.mark.integration


@pytest.fixture
def setup(client: TestClient, db: Session, make_user, make_cash_register) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    """Menu de démo, 2 tables, un caissier et un responsable, une session ouverte."""
    load_demo_menu(db)
    db.add_all([RestaurantTable(label="1", sort_order=0), RestaurantTable(label="2", sort_order=1)])
    db.commit()
    make_user("111111", UserRole.CAISSIER)
    make_user("222222", UserRole.RESPONSABLE)
    register: CashRegister = make_cash_register()
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "open"},
        json={"cash_register_id": str(register.id), "opening_float_xof": 20000},
    )
    assert opened.status_code == 201, opened.text
    products = {p.name: str(p.id) for p in db.scalars(select(Product))}
    tables = {t.label: str(t.id) for t in db.scalars(select(RestaurantTable))}
    return {
        "cashier": cashier,
        "manager": manager,
        "products": products,
        "tables": tables,
        "session_id": opened.json()["id"],
    }


def _create(client: TestClient, headers: dict[str, str], **body: Any) -> dict[str, Any]:
    resp = client.post("/api/v1/orders", headers=headers, json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["order"]  # type: ignore[no-any-return]


def _add(
    client: TestClient, headers: dict[str, str], order_id: str, product_id: str, qty: int = 1
) -> dict[str, Any]:
    resp = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": product_id, "quantity": qty},
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["order"]  # type: ignore[no-any-return]


def test_order_requires_open_session(client: TestClient, make_user) -> None:  # type: ignore[no-untyped-def]
    make_user("111111", UserRole.CAISSIER)
    headers = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    resp = client.post("/api/v1/orders", headers=headers, json={"table_id": None})
    assert resp.status_code == 409
    assert resp.json()["code"] == "NO_OPEN_SESSION"


def test_table_order_totals_and_occupation(client: TestClient, setup: dict[str, Any]) -> None:
    cashier, p = setup["cashier"], setup["products"]
    table_id = setup["tables"]["1"]
    order = _create(client, cashier, table_id=table_id, guests_count=4)
    assert order["status"] == "OPEN"
    assert order["counter_number"] is None
    assert order["order_number"].endswith("-0001")

    _add(client, cashier, order["id"], p["Poisson braisé"], 2)
    _add(client, cashier, order["id"], p["Attiéké"])
    order = _add(client, cashier, order["id"], p["Sucrerie 33cl"], 3)
    # régime TEE (taux par défaut 0 %) : HT = TTC, pas de TVA
    assert order["total_ttc_xof"] == 9500
    assert order["total_ht_xof"] == 9500
    assert order["total_vat_xof"] == 0
    assert order["due_xof"] == 9500
    assert [(i["name"], i["quantity"], i["line_total_xof"]) for i in order["items"]] == [
        ("Poisson braisé", 2, 7000),
        ("Attiéké", 1, 1000),
        ("Sucrerie 33cl", 3, 1500),
    ]

    dup = client.post("/api/v1/orders", headers=cashier, json={"table_id": table_id})
    assert dup.status_code == 409
    assert dup.json()["code"] == "TABLE_ALREADY_OCCUPIED"
    assert dup.json()["meta"]["order_id"] == order["id"]

    board = client.get("/api/v1/tables/board", headers=cashier).json()
    by_label = {t["label"]: t for t in board["tables"]}
    assert by_label["1"]["status"] == "OCCUPIED"
    assert by_label["1"]["order"]["total_ttc_xof"] == 9500
    assert by_label["2"]["status"] == "FREE"


def test_vat_split_for_taxable_products(
    client: TestClient, db: Session, setup: dict[str, Any]
) -> None:
    """Établissement assujetti : exemple du contrat, 9 500 TTC à 18 % → 8 051 HT + 1 449 TVA."""
    for product in db.scalars(select(Product)):
        product.vat_rate = Decimal("18.00")
    db.commit()
    cashier, p = setup["cashier"], setup["products"]
    order = _create(client, cashier, table_id=None)
    _add(client, cashier, order["id"], p["Poisson braisé"], 2)
    _add(client, cashier, order["id"], p["Attiéké"])
    order = _add(client, cashier, order["id"], p["Sucrerie 33cl"], 3)
    assert (order["total_ttc_xof"], order["total_ht_xof"], order["total_vat_xof"]) == (
        9500,
        8051,
        1449,
    )


def test_takeaway_gets_counter_number(client: TestClient, setup: dict[str, Any]) -> None:
    first = _create(client, setup["cashier"], table_id=None)
    second = _create(client, setup["cashier"])
    assert (first["counter_number"], second["counter_number"]) == (1, 2)
    assert first["table_id"] is None


def test_update_item_quantity_and_note(client: TestClient, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    order = _create(client, cashier, table_id=setup["tables"]["1"])
    order = _add(client, cashier, order["id"], setup["products"]["Poisson braisé"])
    item_id = order["items"][0]["id"]
    resp = client.patch(
        f"/api/v1/orders/{order['id']}/items/{item_id}",
        headers=cashier,
        json={"quantity": 3, "note": "bien cuit"},
    )
    assert resp.status_code == 200, resp.text
    updated = resp.json()["order"]
    assert updated["total_ttc_xof"] == 10500
    assert updated["items"][0]["note"] == "bien cuit"
    # champ absent = inchangé ; null explicite = effacé
    cleared = client.patch(
        f"/api/v1/orders/{order['id']}/items/{item_id}", headers=cashier, json={"note": None}
    ).json()["order"]
    assert cleared["items"][0]["quantity"] == 3
    assert cleared["items"][0]["note"] is None


def test_cashier_removes_item_without_override(client: TestClient, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    order = _create(client, cashier, table_id=setup["tables"]["1"])
    _add(client, cashier, order["id"], setup["products"]["Poisson braisé"])
    order = _add(client, cashier, order["id"], setup["products"]["Attiéké"])
    item_url = f"/api/v1/orders/{order['id']}/items/{order['items'][0]['id']}"

    assert client.delete(item_url, headers=cashier).status_code == 422  # motif obligatoire

    resp = client.delete(f"{item_url}?reason=erreur de saisie", headers=cashier)
    assert resp.status_code == 200, resp.text
    after = resp.json()["order"]
    assert after["total_ttc_xof"] == 1000
    assert [i["name"] for i in after["items"]] == ["Attiéké"]

    again = client.delete(f"{item_url}?reason=x", headers=cashier)
    assert again.status_code == 404  # déjà retirée

    x = client.get(f"/api/v1/cash-sessions/{setup['session_id']}/x-report", headers=cashier)
    assert x.json()["totals"]["controls"]["removed_items"] == 1


def test_cancel_frees_table_and_freezes_order(client: TestClient, setup: dict[str, Any]) -> None:
    cashier, manager = setup["cashier"], setup["manager"]
    table_id = setup["tables"]["1"]
    order = _create(client, cashier, table_id=table_id)
    _add(client, cashier, order["id"], setup["products"]["Poisson braisé"])

    refused = client.post(
        f"/api/v1/orders/{order['id']}/cancel", headers=cashier, json={"reason": "client parti"}
    )
    assert refused.json()["code"] == "OVERRIDE_REQUIRED"

    resp = client.post(
        f"/api/v1/orders/{order['id']}/cancel", headers=manager, json={"reason": "client parti"}
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["order"]["status"] == "CANCELLED"

    frozen = client.post(
        f"/api/v1/orders/{order['id']}/items",
        headers=cashier,
        json={"product_id": setup["products"]["Attiéké"]},
    )
    assert frozen.status_code == 409
    assert frozen.json()["code"] == "ORDER_NOT_EDITABLE"
    # la table est de nouveau libre
    _create(client, cashier, table_id=table_id)

    x = client.get(f"/api/v1/cash-sessions/{setup['session_id']}/x-report", headers=cashier)
    totals = x.json()["totals"]
    assert totals["by_fiscal_group"] == []  # une commande annulée n'est pas une vente
    assert totals["controls"]["cancelled_orders"] == 1


def test_list_orders_history_restricted(client: TestClient, setup: dict[str, Any]) -> None:
    cashier, manager = setup["cashier"], setup["manager"]
    _create(client, cashier, table_id=setup["tables"]["1"])
    _create(client, cashier)
    today = client.get("/api/v1/orders", headers=cashier)
    assert today.status_code == 200
    assert len(today.json()["items"]) == 2
    only_open = client.get("/api/v1/orders?status=PAID", headers=cashier).json()["items"]
    assert only_open == []

    other_day = "/api/v1/orders?business_date=2020-01-01"
    assert client.get(other_day, headers=cashier).status_code == 403
    assert client.get(other_day, headers=manager).json()["items"] == []


def test_list_orders_pages_with_cursor(client: TestClient, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    created = [_create(client, cashier)["id"] for _ in range(5)]
    seen: list[str] = []
    url = "/api/v1/orders?limit=2"
    pages = 0
    while url:
        page = client.get(url, headers=cashier).json()
        pages += 1
        seen += [o["id"] for o in page["items"]]
        cursor = page["next_cursor"]
        url = f"/api/v1/orders?limit=2&cursor={cursor}" if cursor else ""
    assert pages == 3
    assert seen == created[::-1]  # plus récentes en premier, ni doublon ni oubli

    exact = client.get("/api/v1/orders?limit=5", headers=cashier).json()
    assert len(exact["items"]) == 5
    assert exact["next_cursor"] is None

    bad = client.get("/api/v1/orders?cursor=pas-un-curseur", headers=cashier)
    assert bad.status_code == 422
    assert bad.json()["code"] == "VALIDATION_ERROR"
    assert client.get("/api/v1/orders?limit=501", headers=cashier).status_code == 422


def test_custom_product_is_orderable_but_not_listed(
    client: TestClient, db: Session, setup: dict[str, Any]
) -> None:
    cashier = setup["cashier"]
    category_id = str(db.scalar(select(Category.id).where(Category.name == "Poissons")))
    resp = client.post(
        "/api/v1/products/custom",
        headers=cashier,
        json={"name": "Poisson capitaine 1 kg", "price_xof": 9000, "category_id": category_id},
    )
    assert resp.status_code == 201, resp.text
    custom = resp.json()
    assert custom["is_custom"] is True
    listed = client.get("/api/v1/products", headers=cashier).json()["items"]
    assert custom["id"] not in {p["id"] for p in listed}

    order = _create(client, cashier)
    order = _add(client, cashier, order["id"], custom["id"])
    assert order["items"][0]["name"] == "Poisson capitaine 1 kg"
    assert order["total_ttc_xof"] == 9000


def test_price_is_frozen_on_line(client: TestClient, db: Session, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    order = _create(client, cashier)
    _add(client, cashier, order["id"], setup["products"]["Alloco"])
    product = db.scalar(select(Product).where(Product.name == "Alloco"))
    assert product is not None
    product.price_xof = 1500
    db.commit()
    detail = client.get(f"/api/v1/orders/{order['id']}", headers=cashier).json()
    assert detail["items"][0]["unit_price_xof"] == 1000
    assert detail["total_ttc_xof"] == 1000
