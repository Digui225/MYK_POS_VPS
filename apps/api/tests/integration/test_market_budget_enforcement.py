from decimal import Decimal
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.stock import StockArticle
from caisse.models.user import User
from caisse.security import hash_pin


def _setup_users(db_session: Session) -> None:
    econome = db_session.query(User).filter(User.role == "ECONOME").first()
    if not econome:
        econome = User(full_name="Économe Test", pin_hash=hash_pin("112233"), role="ECONOME", is_active=True)
        db_session.add(econome)
    else:
        econome.pin_hash = hash_pin("112233")
        econome.is_active = True

    responsable = db_session.query(User).filter(User.role == "RESPONSABLE").first()
    if not responsable:
        responsable = User(full_name="Responsable Test", pin_hash=hash_pin("654321"), role="RESPONSABLE", is_active=True)
        db_session.add(responsable)
    else:
        responsable.pin_hash = hash_pin("654321")
        responsable.is_active = True

    db_session.commit()


def test_market_budget_status_endpoint_for_econome(client: TestClient, db_session: Session) -> None:
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "112233", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    # Requête de statut pour 60 000 XOF
    resp = client.get("/api/v1/purchases/market/budget-status?total_budget_xof=60000", headers=headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["is_exceeded"] is False
    assert data["color_class"] == "emerald"
    assert data["percentage"] == 20
    # Montants visibles pour l'économe
    assert data.get("total_budget_xof") == 60000
    assert data.get("total_limit_xof") == 300000


def test_market_budget_status_endpoint_for_responsable(client: TestClient, db_session: Session) -> None:
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    resp = client.get("/api/v1/purchases/market/budget-status?total_budget_xof=50000", headers=headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["total_budget_xof"] == 50000
    assert data["total_limit_xof"] == 300000
    assert data["econome_limit_xof"] == 300000
    assert data["remaining_budget_xof"] == 250000


def test_market_purchase_creation_blocked_when_econome_exceeds_limit(client: TestClient, db_session: Session) -> None:
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "112233", "device_id": "pos-01"})
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    art = StockArticle(
        name="Poulet Test Budget",
        category="PROTEINE",
        unit="pièce",
        out_mode="RECIPE",
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("3000"),
    )
    db_session.add(art)
    db_session.commit()

    # 101 poulets à 3000 = 303 000 XOF (> 300 000 plafond économe)
    resp = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-10-24",
            "notes": "Commande excessive économe",
            "items": [{"article_id": art.id, "quantity": 101, "unit_price_xof": 3000}],
        },
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()
    assert err["code"] == "MARKET_BUDGET_EXCEEDED"


def test_market_purchase_creation_blocked_when_responsable_exceeds_total_envelope(client: TestClient, db_session: Session) -> None:
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    art = StockArticle(
        name="Bœuf Test Budget Total",
        category="PROTEINE",
        unit="kg",
        out_mode="RECIPE",
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("4000"),
    )
    db_session.add(art)
    db_session.commit()

    # 80 kg à 4000 = 320 000 XOF (> 300 000 plafond absolu)
    resp = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-10-24",
            "notes": "Commande excessive patron",
            "items": [{"article_id": art.id, "quantity": 80, "unit_price_xof": 4000}],
        },
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()
    assert err["code"] == "MARKET_BUDGET_EXCEEDED"


def test_purchase_request_creation_blocked_when_exceeding_budget(client: TestClient, db_session: Session) -> None:
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "112233", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01", "Idempotency-Key": "idem-budget-req-01"}

    art = StockArticle(
        name="Poisson Test Purchase Request",
        category="PROTEINE",
        unit="kg",
        out_mode="RECIPE",
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("5000"),
    )
    db_session.add(art)
    db_session.commit()

    # 65 kg à 5000 = 325 000 XOF (> 300 000 plafond marché)
    resp = client.post(
        "/api/v1/purchases",
        headers=headers,
        json={
            "note": "Demande excessive",
            "lines": [{"article_id": str(art.id), "quantity": 65.0}],
        },
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()
    assert err["code"] == "MARKET_BUDGET_EXCEEDED"
