"""Livraison à la caisse : comme l'emporter (sans table, ni client ni frais), mais comptée à part.

- la commande porte son mode (SUR_PLACE, EMPORTER, LIVRAISON), cohérent avec la table ;
- l'historique, le tableau de bord et les rapports séparent la livraison de l'emporter.
"""

from datetime import date
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product

CAISSE = "pos-terminal-01"


def _bearer(client: TestClient, pin: str) -> dict[str, str]:
    res = client.post("/api/v1/auth/login", json={"pin": pin, "device_id": CAISSE})
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": CAISSE}


@pytest.fixture
def caisse(client: TestClient, db_session: Session) -> dict[str, Any]:
    plats = Category(name="Plats", kind="FOOD", sort_order=1)
    db_session.add(plats)
    db_session.flush()
    brochet = Product(category_id=plats.id, name="Plat brochet", short_name="BROCHET", price_xof=3500)
    db_session.add(brochet)
    db_session.commit()

    headers = _bearer(client, "123456")
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "livraison-session"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": date.today().isoformat()},
    )
    assert opened.status_code == 201, opened.text
    return {"headers": headers, "brochet": brochet.id}


def _open(client: TestClient, headers: dict[str, str], **body: Any) -> dict[str, Any]:
    res = client.post("/api/v1/orders", headers=headers, json=body)
    assert res.status_code == 201, res.text
    return dict(res.json())


def _sell(client: TestClient, caisse: dict[str, Any], order_id: str, key: str) -> None:
    headers = caisse["headers"]
    line = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers={**headers, "Idempotency-Key": f"ligne-{key}"},
        json={"product_id": caisse["brochet"]},
    )
    assert line.status_code == 200, line.text
    paid = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": f"paiement-{key}"},
        json={"method": "CASH", "amount_xof": 3500, "tendered_xof": 3500},
    )
    assert paid.status_code == 201, paid.text


def test_service_mode_follows_the_table(client: TestClient, caisse: dict[str, Any]) -> None:
    headers = caisse["headers"]
    assert _open(client, headers, table_id="tbl-01")["service_mode"] == "SUR_PLACE"
    assert _open(client, headers)["service_mode"] == "EMPORTER"  # sans table : à emporter, comme avant
    delivery = _open(client, headers, service_mode="LIVRAISON")
    assert delivery["service_mode"] == "LIVRAISON" and delivery["table_id"] is None

    on_table = client.post("/api/v1/orders", headers=headers, json={"table_id": "tbl-02", "service_mode": "LIVRAISON"})
    no_table = client.post("/api/v1/orders", headers=headers, json={"service_mode": "SUR_PLACE"})
    assert on_table.status_code == no_table.status_code == 422
    assert on_table.json()["code"] == "INVALID_SERVICE_MODE"


def test_delivery_is_counted_apart_from_takeaway(client: TestClient, caisse: dict[str, Any]) -> None:
    headers = caisse["headers"]
    takeaway = _open(client, headers, service_mode="EMPORTER")
    delivery = _open(client, headers, service_mode="LIVRAISON")
    _sell(client, caisse, takeaway["id"], "a")
    _sell(client, caisse, delivery["id"], "b")

    kpis = client.get("/api/v1/reports/dashboard", headers=headers).json()
    assert (kpis["takeaway_orders_count"], kpis["delivery_orders_count"]) == (1, 1)

    overview = client.get("/api/v1/reports/overview", headers=_bearer(client, "654321")).json()
    assert (overview["takeaway_orders"], overview["delivery_orders"]) == (1, 1)

    def ids(order_type: str) -> set[str]:
        page = client.get(f"/api/v1/orders?order_type={order_type}", headers=headers).json()
        return {o["id"] for o in page["items"]}

    assert ids("DELIVERY") == {delivery["id"]}
    assert ids("TAKEAWAY") == {takeaway["id"]}


def test_dashboard_splits_sales_and_hours_by_service_mode(client: TestClient, caisse: dict[str, Any]) -> None:
    headers = caisse["headers"]
    for key, body in (("s", {"table_id": "tbl-01"}), ("e", {}), ("l1", {"service_mode": "LIVRAISON"}),
                      ("l2", {"service_mode": "LIVRAISON"})):
        _sell(client, caisse, _open(client, headers, **body)["id"], key)
    _open(client, headers, service_mode="LIVRAISON")  # pas encore réglée : hors chiffre d'affaires

    kpis = client.get("/api/v1/reports/dashboard", headers=headers).json()
    by_mode = {m["service_mode"]: m for m in kpis["sales_by_mode"]}
    assert [m["service_mode"] for m in kpis["sales_by_mode"]] == ["SUR_PLACE", "EMPORTER", "LIVRAISON"]
    assert (by_mode["SUR_PLACE"]["orders_count"], by_mode["SUR_PLACE"]["total_sales_ttc_xof"]) == (1, 3500)
    assert (by_mode["EMPORTER"]["orders_count"], by_mode["EMPORTER"]["total_sales_ttc_xof"]) == (1, 3500)
    assert by_mode["LIVRAISON"] == {
        "service_mode": "LIVRAISON",
        "orders_count": 2,
        "total_sales_ttc_xof": 7000,
        "average_basket_xof": 3500,
    }
    assert sum(m["total_sales_ttc_xof"] for m in kpis["sales_by_mode"]) == kpis["total_sales_ttc_xof"]

    hours = kpis["hourly_sales"]
    assert sum(h["dine_in_sales_xof"] for h in hours) == 3500
    assert sum(h["takeaway_sales_xof"] for h in hours) == 3500
    assert sum(h["delivery_sales_xof"] for h in hours) == 7000
    for h in hours:
        assert h["dine_in_sales_xof"] + h["takeaway_sales_xof"] + h["delivery_sales_xof"] == h["total_sales_xof"]
