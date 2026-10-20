import csv
import io
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.domain.enums import FneDocumentType, FneStatus, UserRole
from caisse.models import CashRegister, FneDocument, Product, RestaurantTable, StockArticle
from caisse.security import utcnow
from caisse.seeds.demo import load_demo_menu

from .conftest import FakePrintAgent, auth, login

pytestmark = pytest.mark.integration


@pytest.fixture
def setup(client: TestClient, db: Session, make_user) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    load_demo_menu(db)
    db.add_all([RestaurantTable(label="1"), RestaurantTable(label="2")])
    register = CashRegister(name="Caisse 1", printer_config={})
    db.add(register)
    db.commit()
    make_user("111111", UserRole.CAISSIER, name="Awa")
    make_user("222222", UserRole.RESPONSABLE)
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    session = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "open"},
        json={"cash_register_id": str(register.id), "opening_float_xof": 0},
    ).json()
    return {
        "cashier": cashier,
        "manager": manager,
        "session": session,
        "products": {p.name: str(p.id) for p in db.scalars(select(Product))},
        "tables": [
            str(t.id) for t in db.scalars(select(RestaurantTable).order_by(RestaurantTable.label))
        ],
    }


def _order(client: TestClient, s: dict[str, Any], lines: dict[str, int], **body: Any) -> str:
    order_id: str = client.post("/api/v1/orders", headers=s["cashier"], json=body).json()["order"][
        "id"
    ]
    for name, quantity in lines.items():
        client.post(
            f"/api/v1/orders/{order_id}/items",
            headers=s["cashier"],
            json={"product_id": s["products"][name], "quantity": quantity},
        )
    return order_id


def _pay(client: TestClient, s: dict[str, Any], order_id: str, **body: Any) -> None:
    resp = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**s["cashier"], "Idempotency-Key": f"p-{order_id}"},
        json=body,
    )
    assert resp.status_code == 201, resp.text


def test_dashboard(client: TestClient, setup: dict[str, Any], db: Session) -> None:
    s = setup
    table_order = _order(client, s, {"Poisson braisé": 2}, table_id=s["tables"][0], guests_count=2)
    _pay(client, s, table_order, method="MOBILE_MONEY", provider="WAVE", amount_xof=7000)
    takeaway = _order(client, s, {"Alloco": 1, "Sucrerie 33cl": 2})
    _pay(client, s, takeaway, method="CASH", amount_xof=2000)
    _order(client, s, {"Alloco": 1}, table_id=s["tables"][1])  # reste ouverte
    cancelled = _order(client, s, {"Alloco": 1})
    client.post(f"/api/v1/orders/{cancelled}/cancel", headers=s["manager"], json={"reason": "x"})
    soda = db.scalars(select(StockArticle).where(StockArticle.name == "Jus de bissap")).one()
    soda.alert_threshold = soda.quantity
    db.commit()

    assert client.get("/api/v1/reports/dashboard", headers=s["cashier"]).status_code == 403
    board = client.get("/api/v1/reports/dashboard", headers=s["manager"]).json()
    assert board["business_date"] == s["session"]["business_date"]
    assert (board["revenue_xof"], board["orders_paid"], board["average_ticket_xof"]) == (
        9000,
        2,
        4500,
    )
    assert (board["orders_open"], board["orders_cancelled"], board["guests_count"]) == (1, 1, 2)
    assert (board["dine_in_orders"], board["takeaway_orders"]) == (1, 1)
    assert (board["tables_occupied"], board["tables_total"]) == (1, 2)
    assert board["payments"] == [
        {"method": "MOBILE_MONEY", "provider": "WAVE", "count": 1, "amount_xof": 7000},
        {"method": "CASH", "provider": None, "count": 1, "amount_xof": 2000},
    ]
    assert [p["name"] for p in board["top_products"]] == [
        "Poisson braisé",
        "Alloco",
        "Sucrerie 33cl",
    ]
    assert [(h["hour"], h["orders_count"]) for h in board["hourly"]] == [(utcnow().hour, 2)]
    assert [(c["full_name"], c["revenue_xof"]) for c in board["by_cashier"]] == [("Awa", 9000)]
    assert [(x["cash_register"], x["opened_by"], x["status"]) for x in board["sessions"]] == [
        ("Caisse 1", "Awa", "OPEN")
    ]
    assert board["low_stock_articles"] == 1
    assert board["fne"] == {"certified": 0, "pending": 0}

    empty = client.get(
        "/api/v1/reports/dashboard?business_date=2020-01-01", headers=s["manager"]
    ).json()
    assert (empty["revenue_xof"], empty["orders_paid"], empty["sessions"]) == (0, 0, [])


def test_z_reprint(client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent) -> None:
    s = setup
    url = f"/api/v1/cash-sessions/{s['session']['id']}"
    early = client.post(f"{url}/z-report/reprint", headers=s["cashier"])
    assert (early.status_code, early.json()["code"]) == (409, "SESSION_NOT_CLOSED")
    closed = client.post(
        f"{url}/close",
        headers={**s["cashier"], "Idempotency-Key": "close"},
        json={"counted_breakdown": {}, "notes": None},
    )
    assert closed.status_code == 201, closed.text
    print_agent.run()
    first_z = print_agent.printed[-1]
    again = client.post(f"{url}/z-report/reprint", headers=s["cashier"])
    assert again.status_code == 200, again.text
    job = again.json()
    assert (job["type"], job["is_reprint"], job["status"]) == ("Z_REPORT", True, "QUEUED")
    print_agent.run()
    assert print_agent.printed[-1] == first_z  # contenu figé, pas recalculé
    assert (
        client.post(
            "/api/v1/cash-sessions/" + s["tables"][0] + "/z-report/reprint", headers=s["cashier"]
        ).status_code
        == 404
    )


def test_fne_export_and_customer(client: TestClient, setup: dict[str, Any], db: Session) -> None:
    s = setup
    customer = client.post(
        "/api/v1/customers",
        headers=s["cashier"],
        json={"company_name": "SOCIETE X; Y", "ncc": "9506466A"},
    ).json()
    detail = client.get(f"/api/v1/customers/{customer['id']}", headers=s["cashier"])
    assert detail.json()["company_name"] == "SOCIETE X; Y"
    assert (
        client.get(f"/api/v1/customers/{s['tables'][0]}", headers=s["cashier"]).status_code == 404
    )

    order_id = _order(client, s, {"Alloco": 1})
    _pay(client, s, order_id, method="CASH", amount_xof=1000)
    db.add(
        FneDocument(
            type=FneDocumentType.FNE,
            order_id=order_id,
            customer_id=customer["id"],
            status=FneStatus.CERTIFIED,
            payload={},
            external_number="FNE-0001",
            fne_amount_ttc_xof=1000,
            certified_at=utcnow(),
        )
    )
    db.commit()

    assert client.get("/api/v1/fne/documents/export", headers=s["cashier"]).status_code == 403
    resp = client.get("/api/v1/fne/documents/export?status=CERTIFIED", headers=s["manager"])
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/csv")
    assert resp.headers["content-disposition"].startswith('attachment; filename="fne-')
    text = resp.content.decode("utf-8")
    assert text.startswith("﻿")
    rows = list(csv.reader(io.StringIO(text.lstrip("﻿")), delimiter=";"))
    assert rows[0][:5] == ["cree_le", "journee", "commande", "type", "statut"]
    assert rows[1][3:10] == [
        "FNE",
        "CERTIFIED",
        "non",
        "FNE-0001",
        "SOCIETE X; Y",
        "9506466A",
        "1000",
    ]
    none = client.get("/api/v1/fne/documents/export?status=FAILED", headers=s["manager"])
    assert len(none.content.decode().lstrip("﻿").strip().splitlines()) == 1
