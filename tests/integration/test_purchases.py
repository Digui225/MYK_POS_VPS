"""Approvisionnement : demande de l'acheteur (sans prix) → validation → décaissement →
réception (entrées de stock)."""

from typing import Any

import pytest
from fastapi.testclient import TestClient

from caisse.domain.enums import UserRole

from .conftest import auth, login

pytestmark = pytest.mark.integration

PRICE_FIELDS = {"unit_price_xof", "avg_cost_xof", "value_xof", "amount_xof", "price_missing"}


@pytest.fixture
def setup(client: TestClient, make_user) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    """Bœuf (achats à 4 000 puis 5 000), Tomate (coût 1 000, jamais achetée), Sel (sans prix)."""
    make_user("111111", UserRole.ACHETEUR, name="Fatou Achats")
    make_user("222222", UserRole.RESPONSABLE)
    make_user("333333", UserRole.ACHETEUR, name="Autre acheteur")
    make_user("444444", UserRole.CAISSIER)
    buyer = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    articles = {}
    for name, category, cost in (
        ("Bœuf", "PROTEINE", 4000),
        ("Tomate", "EPICERIE", 1000),
        ("Sel", "EPICERIE", 0),
    ):
        resp = client.post(
            "/api/v1/stock/articles",
            headers=manager,
            json={
                "name": name,
                "category": category,
                "unit": "kg",
                "out_mode": "INVENTORY",
                "avg_cost_xof": cost,
            },
        )
        assert resp.status_code == 201, resp.text
        articles[name] = resp.json()["id"]
    for key, quantity, total in (("r1", 10, 40000), ("r2", 2, 10000)):
        resp = client.post(
            "/api/v1/stock/receipts",
            headers={**manager, "Idempotency-Key": key},
            json={
                "lines": [
                    {"article_id": articles["Bœuf"], "quantity": quantity, "total_cost_xof": total}
                ]
            },
        )
        assert resp.status_code == 201, resp.text
    return {"buyer": buyer, "manager": manager, "articles": articles}


def _submit(client: TestClient, setup: dict[str, Any], key: str = "p1") -> Any:
    a = setup["articles"]
    return client.post(
        "/api/v1/purchases",
        headers={**setup["buyer"], "Idempotency-Key": key},
        json={
            "note": "Marché du matin",
            "lines": [
                {"article_id": a["Bœuf"], "quantity": 3},
                {"article_id": a["Tomate"], "quantity": 2},
                {"article_id": a["Sel"], "quantity": 1},
            ],
        },
    )


def _lines(client: TestClient, setup: dict[str, Any], purchase_id: str) -> dict[str, Any]:
    detail = client.get(f"/api/v1/purchases/{purchase_id}", headers=setup["manager"]).json()
    return {line["article_name"]: line for line in detail["lines"]}


def test_buyer_sees_no_price_and_only_purchase_routes(
    client: TestClient, setup: dict[str, Any]
) -> None:
    buyer = setup["buyer"]
    listed = client.get("/api/v1/purchases/articles?category=EPICERIE", headers=buyer)
    assert listed.status_code == 200, listed.text
    items = listed.json()["items"]
    assert [a["name"] for a in items] == ["Sel", "Tomate"]
    assert not PRICE_FIELDS & set(items[0])

    assert client.get("/api/v1/auth/me", headers=buyer).json()["user"]["role"] == "ACHETEUR"
    for path in (
        "/api/v1/orders",
        "/api/v1/stock/articles",
        "/api/v1/products",
        "/api/v1/purchases",
    ):
        resp = client.get(path, headers=buyer)
        assert resp.status_code == 403, path
        assert resp.json()["code"] == "INSUFFICIENT_PRIVILEGE"
    cashier = auth(login(client, "444444")["access_token"])  # type: ignore[arg-type]
    assert client.get("/api/v1/purchases/articles", headers=cashier).status_code == 200


def test_full_cycle_from_request_to_stock_entry(client: TestClient, setup: dict[str, Any]) -> None:
    buyer, manager = setup["buyer"], setup["manager"]
    created = _submit(client, setup)
    assert created.status_code == 201, created.text
    request = created.json()
    # dernier prix d'achat du bœuf (5 000, pas le coût moyen 4 167) ; sel sans prix : 0
    assert request["amount_xof"] == 3 * 5000 + 2 * 1000
    assert request["number"] == "ACH-0001"
    assert request["status"] == "SUBMITTED"
    assert all(not PRICE_FIELDS & set(line) for line in request["lines"])

    replay = _submit(client, setup)
    assert replay.status_code == 200
    assert replay.headers["Idempotent-Replay"] == "true"
    assert replay.json()["id"] == request["id"]

    pending = client.get("/api/v1/purchases/pending-count", headers=manager).json()
    assert pending == {"submitted": 1, "approved": 0, "disbursed": 0}
    listed = client.get("/api/v1/purchases?status=SUBMITTED", headers=manager).json()["items"]
    assert [(p["number"], p["requested_by"]["full_name"], p["line_count"]) for p in listed] == [
        ("ACH-0001", "Fatou Achats", 3)
    ]
    lines = _lines(client, setup, request["id"])
    assert lines["Bœuf"]["unit_price_xof"] == 5000
    assert lines["Sel"]["price_missing"] is True

    url = f"/api/v1/purchases/{request['id']}"
    approved = client.post(
        f"{url}/approve",
        headers=manager,
        json={
            "lines": [
                {"line_id": lines["Bœuf"]["id"], "quantity": 2.5},
                {"line_id": lines["Sel"]["id"], "unit_price_xof": 300},
            ]
        },
    )
    assert approved.status_code == 200, approved.text
    assert approved.json()["approved_total_xof"] == 12500 + 2000 + 300
    mine = client.get(f"/api/v1/purchases/mine/{request['id']}", headers=buyer).json()
    assert (mine["status"], mine["amount_xof"]) == ("APPROVED", 14800)

    disbursed = client.post(f"{url}/disburse", headers=manager, json={})
    assert disbursed.status_code == 200, disbursed.text
    assert disbursed.json()["disbursed_xof"] == 14800

    received = client.post(
        f"{url}/receive",
        headers=manager,
        json={
            "supplier": "Marché de Treichville",
            "lines": [
                {"line_id": lines["Bœuf"]["id"], "quantity": 2.5, "total_cost_xof": 13000},
                {"line_id": lines["Tomate"]["id"], "quantity": 2, "total_cost_xof": 1500},
            ],
        },
    )
    assert received.status_code == 200, received.text
    body = received.json()
    assert (body["status"], body["received_total_xof"], body["change_due_xof"]) == (
        "RECEIVED",
        14500,
        300,
    )
    after = {line["article_name"]: line for line in body["lines"]}
    assert after["Sel"]["received_quantity"] == 0  # validé mais pas trouvé

    stock = {
        a["name"]: a for a in client.get("/api/v1/stock/articles", headers=manager).json()["items"]
    }
    assert stock["Bœuf"]["quantity"] == 14.5
    assert stock["Tomate"]["quantity"] == 2
    assert stock["Tomate"]["avg_cost_xof"] == 750  # prix payé : 1 500 pour 2 kg
    assert stock["Sel"]["quantity"] == 0
    movements = client.get("/api/v1/stock/movements?type=PURCHASE_IN", headers=manager).json()[
        "items"
    ]
    assert movements[0]["reason"] == "Demande d'achat ACH-0001"
    assert movements[0]["supplier"] == "Marché de Treichville"

    mine = client.get(f"/api/v1/purchases/mine/{request['id']}", headers=buyer).json()
    assert (mine["disbursed_xof"], mine["received_total_xof"], mine["change_due_xof"]) == (
        14800,
        14500,
        300,
    )
    assert client.get("/api/v1/purchases/pending-count", headers=manager).json() == {
        "submitted": 0,
        "approved": 0,
        "disbursed": 0,
    }


def test_state_rules_and_ownership(client: TestClient, setup: dict[str, Any]) -> None:
    manager = setup["manager"]
    other = auth(login(client, "333333")["access_token"])  # type: ignore[arg-type]
    request = _submit(client, setup).json()
    url = f"/api/v1/purchases/{request['id']}"

    assert client.get(f"/api/v1/purchases/mine/{request['id']}", headers=other).status_code == 404
    assert client.get("/api/v1/purchases/mine", headers=other).json()["items"] == []
    stranger = client.post(f"/api/v1/purchases/mine/{request['id']}/cancel", headers=other, json={})
    assert stranger.status_code == 404

    early = client.post(f"{url}/disburse", headers=manager, json={})
    assert early.status_code == 409
    assert early.json()["code"] == "PURCHASE_STATE"
    assert early.json()["meta"]["expected"] == ["APPROVED"]

    lines = _lines(client, setup, request["id"])
    all_zero = [{"line_id": line["id"], "quantity": 0} for line in lines.values()]
    assert (
        client.post(f"{url}/approve", headers=manager, json={"lines": all_zero}).status_code == 422
    )
    assert client.post(f"{url}/approve", headers=manager, json={}).status_code == 200
    assert client.post(f"{url}/approve", headers=manager, json={}).status_code == 409
    late_cancel = client.post(
        f"/api/v1/purchases/mine/{request['id']}/cancel", headers=setup["buyer"], json={}
    )
    assert late_cancel.status_code == 409

    rejected = client.post(f"{url}/reject", headers=manager, json={"reason": "Trop cher"})
    assert rejected.status_code == 200
    mine = client.get(f"/api/v1/purchases/mine/{request['id']}", headers=setup["buyer"]).json()
    assert (mine["status"], mine["closed_reason"]) == ("REJECTED", "Trop cher")


def test_buyer_cancels_and_zero_total_needs_amount(
    client: TestClient, setup: dict[str, Any]
) -> None:
    buyer, manager = setup["buyer"], setup["manager"]
    first = _submit(client, setup, key="p1").json()
    cancelled = client.post(
        f"/api/v1/purchases/mine/{first['id']}/cancel", headers=buyer, json={"reason": "Doublon"}
    )
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "CANCELLED"

    salt_only = client.post(
        "/api/v1/purchases",
        headers={**buyer, "Idempotency-Key": "p2"},
        json={"lines": [{"article_id": setup["articles"]["Sel"], "quantity": 1}]},
    ).json()
    assert salt_only["amount_xof"] == 0
    url = f"/api/v1/purchases/{salt_only['id']}"
    assert client.post(f"{url}/approve", headers=manager, json={}).status_code == 200
    missing = client.post(f"{url}/disburse", headers=manager, json={})
    assert missing.status_code == 422
    given = client.post(f"{url}/disburse", headers=manager, json={"amount_xof": 500})
    assert given.json()["disbursed_xof"] == 500

    unknown = client.post(
        "/api/v1/purchases",
        headers={**buyer, "Idempotency-Key": "p3"},
        json={"lines": [{"article_id": "01a15efc-0000-7000-8000-000000000000", "quantity": 1}]},
    )
    assert unknown.status_code == 404
