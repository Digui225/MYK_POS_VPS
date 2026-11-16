"""Annulation d'une commande depuis la caisse.

- la caissière annule seule une commande à 0 F (vide, ou dont tous les plats ont été retirés) ;
- s'il reste des articles, il faut un responsable ou un admin ;
- jamais après un paiement, même partiel ;
- la commande annulée quitte la salle et reste tracée (motif, auteur, journal d'audit).
"""

from datetime import date
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.audit import AuditLog
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
    riz = Product(category_id=plats.id, name="Riz kope+Boeuf", short_name="RIZ", price_xof=3000)
    db_session.add(riz)
    db_session.commit()

    cashier = _bearer(client, "123456")
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "annulation-session"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 0,
            "business_date": date.today().isoformat(),
        },
    )
    assert opened.status_code == 201, opened.text
    return {"cashier": cashier, "riz": riz.id}


def _delivery_with_dish(client: TestClient, caisse: dict[str, Any]) -> tuple[str, str]:
    headers = caisse["cashier"]
    order = client.post("/api/v1/orders", headers=headers, json={"service_mode": "LIVRAISON"})
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    line = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": caisse["riz"]},
    )
    assert line.status_code == 200, line.text
    item_id = next(it["id"] for it in line.json()["items"] if it["removed_at"] is None)
    return order_id, item_id


def _cancel(client: TestClient, headers: dict[str, str], order_id: str, reason: str) -> Any:
    return client.post(
        f"/api/v1/orders/{order_id}/cancel", headers=headers, json={"reason": reason}
    )


def _open_orders(client: TestClient, headers: dict[str, str]) -> int:
    """Commandes ouvertes, d'où la caisse tire ses cartes Livraison et Emporter."""
    res = client.get("/api/v1/orders", headers=headers, params={"status": "OPEN"})
    assert res.status_code == 200, res.text
    body = res.json()
    return len(body["items"] if isinstance(body, dict) else body)


def test_cashier_cancels_a_note_whose_dishes_were_all_removed(
    client: TestClient, db_session: Session, caisse: dict[str, Any]
) -> None:
    cashier = caisse["cashier"]
    order_id, item_id = _delivery_with_dish(client, caisse)
    removed = client.request(
        "DELETE",
        f"/api/v1/orders/{order_id}/items/{item_id}",
        headers=cashier,
        json={"reason": "Annulation du client"},
    )
    assert removed.status_code == 200, removed.text
    assert removed.json()["total_ttc_xof"] == 0
    assert _open_orders(client, cashier) == 1  # la note à 0 F reste sur le plan

    res = _cancel(client, cashier, order_id, "Erreur de saisie")
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "CANCELLED"
    assert _open_orders(client, cashier) == 0

    db_session.expire_all()
    [log] = db_session.query(AuditLog).filter(
        AuditLog.action == "ORDER_CANCELLED", AuditLog.entity_id == order_id
    ).all()
    assert log.reason == "Erreur de saisie"
    assert log.user_id == "usr-caissier-01"


def test_cashier_cancels_an_empty_note(client: TestClient, caisse: dict[str, Any]) -> None:
    cashier = caisse["cashier"]
    order = client.post("/api/v1/orders", headers=cashier, json={"table_id": "tbl-01"})
    assert order.status_code == 201, order.text
    res = _cancel(client, cashier, order.json()["id"], "Client parti")
    assert res.status_code == 200, res.text


def test_a_manager_is_needed_while_dishes_remain(client: TestClient, caisse: dict[str, Any]) -> None:
    order_id, _ = _delivery_with_dish(client, caisse)

    refused = _cancel(client, caisse["cashier"], order_id, "Client parti")
    assert refused.status_code == 403
    assert refused.json()["code"] == "ORDER_CANCEL_REQUIRES_MANAGER"

    manager = _bearer(client, "654321")
    ok = _cancel(client, manager, order_id, "Client parti")
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "CANCELLED"


def test_no_cancel_after_a_payment(client: TestClient, caisse: dict[str, Any]) -> None:
    order_id, _ = _delivery_with_dish(client, caisse)
    paid = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caisse["cashier"], "Idempotency-Key": "annulation-acompte"},
        json={"method": "CASH", "amount_xof": 1000, "tendered_xof": 1000},
    )
    assert paid.status_code == 201, paid.text

    admin = _bearer(client, "999999")
    res = _cancel(client, admin, order_id, "Client parti")
    assert res.status_code == 409
    assert res.json()["code"] == "ORDER_HAS_PAYMENTS"


def test_reason_is_required(client: TestClient, caisse: dict[str, Any]) -> None:
    order = client.post("/api/v1/orders", headers=caisse["cashier"], json={"table_id": "tbl-01"})
    res = _cancel(client, caisse["cashier"], order.json()["id"], "")
    assert res.status_code == 422
