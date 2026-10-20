from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.domain.enums import UserRole
from caisse.models import AppSetting, CashRegister, Payment, Product, RestaurantTable
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
    register: CashRegister = make_cash_register()
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "open"},
        json={"cash_register_id": str(register.id), "opening_float_xof": 20000},
    )
    assert opened.status_code == 201, opened.text
    return {
        "cashier": cashier,
        "manager": manager,
        "session_id": opened.json()["id"],
        "products": {p.name: str(p.id) for p in db.scalars(select(Product))},
        "table_id": str(db.scalars(select(RestaurantTable)).one().id),
    }


def _order(client: TestClient, setup: dict[str, Any], table: bool = True) -> str:
    """Table 1 (ou comptoir) : 2 poissons braisés + 2 attiékés = 9 000 XOF."""
    headers, p = setup["cashier"], setup["products"]
    body = {"table_id": setup["table_id"] if table else None}
    order_id: str = client.post("/api/v1/orders", headers=headers, json=body).json()["order"]["id"]
    for name in ("Poisson braisé", "Attiéké"):
        resp = client.post(
            f"/api/v1/orders/{order_id}/items",
            headers=headers,
            json={"product_id": p[name], "quantity": 2},
        )
        assert resp.status_code == 201, resp.text
    return order_id


def _pay(client: TestClient, headers: dict[str, str], order_id: str, key: str, **body: Any) -> Any:
    return client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": key},
        json=body,
    )


def test_payment_methods(client: TestClient, setup: dict[str, Any]) -> None:
    methods = client.get("/api/v1/payment-methods", headers=setup["cashier"]).json()
    assert [m["method"] for m in methods] == [
        "CASH",
        "MOBILE_MONEY",
        "CARD",
        "BANK_TRANSFER",
        "CREDIT",
    ]
    cash, mobile = methods[0], methods[1]
    assert cash["gives_change"] is True and cash["providers"] == []
    assert mobile["providers"] == ["ORANGE", "MTN", "MOOV", "WAVE"]


def test_mixed_payment_settles_order_and_frees_table(
    client: TestClient, setup: dict[str, Any]
) -> None:
    cashier = setup["cashier"]
    order_id = _order(client, setup)

    first = _pay(
        client, cashier, order_id, "k1", method="CASH", amount_xof=5000, tendered_xof=10000
    )
    assert first.status_code == 201, first.text
    body = first.json()
    assert body["payment"]["change_xof"] == 5000
    assert body["order"]["status"] == "PARTIALLY_PAID"
    assert (body["order"]["paid_xof"], body["order"]["due_xof"]) == (5000, 4000)
    assert body["receipt"] is None and body["fiscal_document"] is None

    second = _pay(
        client,
        cashier,
        order_id,
        "k2",
        method="MOBILE_MONEY",
        provider="WAVE",
        amount_xof=4000,
        reference="TX8812",
    )
    assert second.status_code == 201, second.text
    order = second.json()["order"]
    assert order["status"] == "PAID"
    assert order["due_xof"] == 0 and order["paid_at"] is not None
    assert [p["method"] for p in order["payments"]] == ["CASH", "MOBILE_MONEY"]

    receipt = second.json()["receipt"]
    assert receipt["status"] == "QUEUED"  # l'agent du terminal le prendra
    assert receipt["drawer_opened"] is None
    assert receipt["print_job_id"]
    assert second.json()["fiscal_document"] is None

    again = _pay(client, cashier, order_id, "k3", method="CASH", amount_xof=100)
    assert again.status_code == 409
    assert again.json()["code"] == "ORDER_NOT_EDITABLE"

    # table libérée : une nouvelle commande peut s'y ouvrir
    reopened = client.post("/api/v1/orders", headers=cashier, json={"table_id": setup["table_id"]})
    assert reopened.status_code == 201, reopened.text

    report = client.get(
        f"/api/v1/cash-sessions/{setup['session_id']}/x-report", headers=cashier
    ).json()
    by_method = {m["method"]: m["amount_xof"] for m in report["totals"]["by_payment_method"]}
    assert by_method == {"CASH": 5000, "MOBILE_MONEY": 4000}
    assert report["expected_cash_xof"] == 25000  # fonds + espèces gardées, pas la somme remise


def test_settling_payment_survives_printer_offline(
    client: TestClient, setup: dict[str, Any]
) -> None:
    """L'imprimante est informative : une vente reste 201 même sans agent en ligne."""
    cashier = setup["cashier"]
    order_id = _order(client, setup)

    resp = _pay(client, cashier, order_id, "k1", method="CASH", amount_xof=9000, tendered_xof=9000)
    assert resp.status_code == 201, resp.text
    order = resp.json()["order"]
    assert order["status"] == "PAID"
    receipt = resp.json()["receipt"]
    assert receipt["status"] == "QUEUED"  # attend le retour de l'agent
    assert receipt["drawer_opened"] is None


def test_payment_rules(client: TestClient, db: Session, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    order_id = _order(client, setup)

    over = _pay(client, cashier, order_id, "a", method="CARD", amount_xof=9500)
    assert over.status_code == 422
    assert over.json()["code"] == "PAYMENT_EXCEEDS_DUE"
    assert over.json()["meta"] == {"due_xof": 9000, "amount_xof": 9500}

    for key, body in {
        "b": {"method": "CARD", "amount_xof": 1000, "tendered_xof": 2000},
        "c": {"method": "MOBILE_MONEY", "amount_xof": 1000},
        "d": {"method": "CASH", "amount_xof": 1000, "tendered_xof": 500},
        "e": {"method": "CASH", "amount_xof": 0},
    }.items():
        resp = _pay(client, cashier, order_id, key, **body)
        assert resp.status_code == 422, body
        assert resp.json()["code"] == "VALIDATION_ERROR"

    disabled = _pay(client, cashier, order_id, "f", method="OTHER", amount_xof=1000)
    assert disabled.status_code == 422
    assert disabled.json()["code"] == "PAYMENT_METHOD_DISABLED"

    db.add(AppSetting(key="payments.methods", value=["CASH", "OTHER"]))
    db.commit()
    assert _pay(client, cashier, order_id, "g", method="OTHER", amount_xof=1000).status_code == 201

    empty = client.post("/api/v1/orders", headers=cashier, json={"table_id": None}).json()
    nothing = _pay(client, cashier, empty["order"]["id"], "h", method="CASH", amount_xof=500)
    assert nothing.status_code == 409
    assert nothing.json()["meta"]["reason"] == "nothing_due"


def test_payment_is_idempotent(client: TestClient, db: Session, setup: dict[str, Any]) -> None:
    cashier = setup["cashier"]
    order_id = _order(client, setup)

    first = _pay(client, cashier, order_id, "same", method="CASH", amount_xof=3000)
    replay = _pay(client, cashier, order_id, "same", method="CASH", amount_xof=3000)
    assert (first.status_code, replay.status_code) == (201, 200)
    assert replay.headers["Idempotent-Replay"] == "true"
    assert replay.json() == first.json()
    assert len(db.scalars(select(Payment)).all()) == 1

    conflict = _pay(client, cashier, order_id, "same", method="CASH", amount_xof=2000)
    assert conflict.status_code == 409
    assert conflict.json()["code"] == "IDEMPOTENCY_CONFLICT"

    # la réponse rejouée est celle d'origine, même si la commande a évolué depuis
    _pay(client, cashier, order_id, "other", method="CASH", amount_xof=1000)
    late = _pay(client, cashier, order_id, "same", method="CASH", amount_xof=3000)
    assert late.json()["order"]["paid_xof"] == 3000


def test_void_payment(client: TestClient, setup: dict[str, Any]) -> None:
    cashier, manager = setup["cashier"], setup["manager"]
    order_id = _order(client, setup)
    payment_id = _pay(client, cashier, order_id, "k1", method="CARD", amount_xof=9000).json()[
        "payment"
    ]["id"]
    url = f"/api/v1/orders/{order_id}/payments/{payment_id}?reason=mauvais%20moyen"

    denied = client.delete(url, headers=cashier)
    assert denied.status_code == 403
    assert denied.json()["code"] == "OVERRIDE_REQUIRED"

    token = client.post(
        "/api/v1/auth/override",
        headers=cashier,
        json={"pin": "222222", "action": "payment.void"},
    ).json()["override_token"]
    voided = client.delete(url, headers={**cashier, "X-Override-Token": token})
    assert voided.status_code == 200, voided.text
    order = voided.json()["order"]
    assert order["status"] == "OPEN"
    assert (order["paid_xof"], order["due_xof"], order["paid_at"]) == (0, 9000, None)
    assert order["payments"][0]["status"] == "VOIDED"
    assert order["payments"][0]["void_reason"] == "mauvais moyen"
    assert voided.json()["warnings"] == []

    twice = client.delete(url, headers=manager)
    assert twice.status_code == 409
    assert twice.json()["meta"]["reason"] == "already_voided"

    # paiements annulés : la commande peut de nouveau être annulée
    cancelled = client.post(
        f"/api/v1/orders/{order_id}/cancel", headers=manager, json={"reason": "client parti"}
    )
    assert cancelled.status_code == 200, cancelled.text


def test_void_allowed_when_table_reoccupied(client: TestClient, setup: dict[str, Any]) -> None:
    """Partage de table : la commande redevient active à côté de celle qui a rouvert la table."""
    cashier, manager = setup["cashier"], setup["manager"]
    order_id = _order(client, setup)
    paid = _pay(client, cashier, order_id, "k1", method="CASH", amount_xof=9000).json()
    next_order = _order(client, setup)

    resp = client.delete(
        f"/api/v1/orders/{order_id}/payments/{paid['payment']['id']}?reason=erreur",
        headers=manager,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["order"]["status"] == "OPEN"
    board = client.get("/api/v1/tables/board", headers=cashier).json()["tables"][0]
    assert [o["id"] for o in board["orders"]] == [order_id, next_order]


def test_void_warns_when_fne_issued(client: TestClient, db: Session, setup: dict[str, Any]) -> None:
    db.add_all(
        [
            AppSetting(key="fne.point_of_sale", value="CAISSE-1"),
            AppSetting(key="fne.establishment", value="RESTAURANT"),
            AppSetting(
                key="fne.walk_in_client",
                value={"company_name": "CLIENT DIVERS", "phone": "0700000000", "email": "a@b.ci"},
            ),
        ]
    )
    db.commit()
    cashier, manager = setup["cashier"], setup["manager"]
    order_id = _order(client, setup, table=False)
    paid = _pay(client, cashier, order_id, "k1", method="CASH", amount_xof=9000).json()
    issued = client.post(f"/api/v1/orders/{order_id}/fne", headers=cashier, json={})
    assert issued.status_code == 201, issued.text

    resp = client.delete(
        f"/api/v1/orders/{order_id}/payments/{paid['payment']['id']}?reason=erreur",
        headers=manager,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["order"]["status"] == "OPEN"
    assert [w["code"] for w in resp.json()["warnings"]] == ["FNE_ALREADY_ISSUED"]


def test_void_refused_after_session_close(client: TestClient, setup: dict[str, Any]) -> None:
    cashier, manager = setup["cashier"], setup["manager"]
    order_id = _order(client, setup)
    paid = _pay(client, cashier, order_id, "k1", method="CASH", amount_xof=9000).json()
    closed = client.post(
        f"/api/v1/cash-sessions/{setup['session_id']}/close",
        headers={**cashier, "Idempotency-Key": "close"},
        json={"counted_breakdown": {"10000": 2, "5000": 1, "2000": 2}},
    )
    assert closed.status_code == 201, closed.text

    resp = client.delete(
        f"/api/v1/orders/{order_id}/payments/{paid['payment']['id']}?reason=erreur",
        headers=manager,
    )
    assert resp.status_code == 409
    assert resp.json()["meta"]["reason"] == "session_closed"
