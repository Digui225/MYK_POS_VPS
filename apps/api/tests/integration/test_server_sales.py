"""Ventes par serveur dans le tableau de bord, l'aperçu du jour (rapport, PDF) et les KPI.

- une note compte pour son serveur, même quand un collègue y a ajouté des plats ;
- les commandes prises à la caisse forment la ligne « Caisse » ;
- seules les additions réglées comptent, et la somme retombe sur le chiffre d'affaires.
"""

from datetime import date
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.models.catalog import Category, Product
from caisse.models.user import User

CAISSE = "pos-terminal-01"


def _bearer(client: TestClient, body: dict[str, Any], device: str) -> dict[str, str]:
    res = client.post("/api/v1/auth/login", json={**body, "device_id": device})
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": device}


@pytest.fixture
def service(client: TestClient, db_session: Session) -> dict[str, Any]:
    plats = Category(name="Plats", kind="FOOD", sort_order=1)
    jus = Category(name="Jus", kind="DRINK", sort_order=2)
    db_session.add_all([plats, jus])
    db_session.flush()
    foufou = Product(category_id=plats.id, name="Foufou bœuf", short_name="FOUFOU", price_xof=3500)
    bissap = Product(category_id=jus.id, name="Jus de bissap", short_name="BISSAP", price_xof=500)
    koffi = User(full_name="Koffi", pin_hash=hash_pin("246810"), role="SERVEUR", is_active=True)
    awa = User(full_name="Awa", pin_hash=hash_pin("135791"), role="SERVEUR", is_active=True)
    db_session.add_all([foufou, bissap, koffi, awa])
    db_session.commit()

    caisse = _bearer(client, {"pin": "123456"}, CAISSE)
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**caisse, "Idempotency-Key": "serveurs-session"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 0,
            "business_date": date.today().isoformat(),
        },
    )
    assert opened.status_code == 201, opened.text
    return {
        "caisse": caisse,
        "koffi": _bearer(client, {"pin": "246810", "user_id": koffi.id}, "tel-01"),
        "awa": _bearer(client, {"pin": "135791", "user_id": awa.id}, "tel-02"),
        "koffi_id": koffi.id,
        "foufou": foufou.id,
        "bissap": bissap.id,
    }


def _note(client: TestClient, headers: dict[str, str], **body: Any) -> str:
    res = client.post("/api/v1/orders", headers=headers, json=body)
    assert res.status_code == 201, res.text
    return str(res.json()["id"])


def _send(client: TestClient, headers: dict[str, str], order_id: str, key: str, *products: str) -> None:
    res = client.post(
        f"/api/v1/orders/{order_id}/dispatch",
        headers={**headers, "Idempotency-Key": key},
        json={"items": [{"product_id": p, "quantity": 1} for p in products]},
    )
    assert res.status_code in (200, 201), res.text


def _pay(client: TestClient, caisse: dict[str, str], order_id: str, amount: int) -> None:
    res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caisse, "Idempotency-Key": f"paiement-{order_id}"},
        json={"method": "CASH", "amount_xof": amount, "tendered_xof": amount},
    )
    assert res.status_code == 201, res.text


def test_sales_by_waiter_add_up_to_revenue(client: TestClient, service: dict[str, Any]) -> None:
    caisse = service["caisse"]
    # Koffi : foufou + bissap, puis Awa ajoute un foufou sur sa note → 7 500 pour Koffi
    koffi_note = _note(client, service["koffi"], table_id="tbl-01")
    _send(client, service["koffi"], koffi_note, "envoi-k1", service["foufou"], service["bissap"])
    _send(client, service["awa"], koffi_note, "envoi-a-sur-k", service["foufou"])
    # Awa : un foufou sur sa table
    awa_note = _note(client, service["awa"], table_id="tbl-02")
    _send(client, service["awa"], awa_note, "envoi-a1", service["foufou"])
    # La caisse : un foufou à emporter, sans serveur
    takeaway = _note(client, caisse, service_mode="EMPORTER")
    _send(client, caisse, takeaway, "envoi-c1", service["foufou"])
    # Encore ouverte : ne compte pas
    open_note = _note(client, service["koffi"], service_mode="LIVRAISON")
    _send(client, service["koffi"], open_note, "envoi-k2", service["foufou"])

    _pay(client, caisse, koffi_note, 7500)
    _pay(client, caisse, awa_note, 3500)
    _pay(client, caisse, takeaway, 3500)

    manager = _bearer(client, {"pin": "654321"}, CAISSE)
    expected = [("Koffi", 1, 7500, 7500), ("Awa", 1, 3500, 3500), ("Caisse", 1, 3500, 3500)]

    overview = client.get("/api/v1/reports/overview", headers=manager).json()
    lines = overview["by_server"]
    assert [(x["server_name"], x["orders_count"], x["total_sales_ttc_xof"], x["average_basket_xof"]) for x in lines] == expected
    assert lines[0]["server_user_id"] == service["koffi_id"]
    assert lines[2]["server_user_id"] is None
    assert sum(x["total_sales_ttc_xof"] for x in lines) == overview["revenue_xof"] == 14500

    kpis = client.get("/api/v1/reports/dashboard", headers=manager).json()
    lines = kpis["sales_by_server"]
    assert [(x["server_name"], x["orders_count"], x["total_sales_ttc_xof"], x["average_basket_xof"]) for x in lines] == expected
    assert sum(x["total_sales_ttc_xof"] for x in lines) == kpis["total_sales_ttc_xof"]
