from decimal import Decimal

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.models.stock import StockArticle
from caisse.models.user import User


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
    assert data["percentage"] == 33  # 60 000 / 180 000 = 33%
    # Montants visibles pour l'économe : plafond limité à 180 000 XOF (protéines), 120 000 XOF reste secret
    assert data.get("total_budget_xof") == 60000
    assert data.get("total_limit_xof") == 180000
    assert data.get("econome_limit_xof") == 180000
    assert data.get("other_envelope_xof") is None


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
    assert data["econome_limit_xof"] == 180000
    assert data["other_envelope_xof"] == 120000
    assert data["real_disbursement_xof"] == 170000  # 50 000 protéines + 120 000 condiments
    assert data["remaining_budget_xof"] == 130000  # 300 000 - 170 000 = 130 000 XOF


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


def test_market_purchase_with_and_without_condiments_envelope(
    client: TestClient, db_session: Session
) -> None:
    """Vérifie qu'un achat d'appoint (sans condiments) ne décaisse que les articles
    et n'injecte aucun condiment, tandis qu'un grand marché avec condiments inclut les 120 000 XOF."""
    _setup_users(db_session)
    login_resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    # 1. Ouvrir une session de caisse
    client.post(
        "/api/v1/sessions/open",
        headers=headers,
        json={"initial_amount_xof": 200000},
    )

    art = StockArticle(
        name="Boeuf Appoint Test",
        category="PROTEINE",
        unit="kg",
        out_mode="RECIPE",
        quantity=Decimal("5"),
        avg_cost_xof=Decimal("4000"),
    )
    db_session.add(art)
    db_session.commit()

    # 2. Création d'un bon d'achat d'appoint : 10 kg de boeuf à 4 000 = 40 000 XOF (sans condiments)
    create_resp = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-11-02",
            "notes": "Achat d'appoint 10kg boeuf",
            "include_condiments_envelope": False,
            "items": [{"article_id": str(art.id), "quantity": 10, "unit_price_xof": 4000}],
        },
    )
    assert create_resp.status_code == 201, create_resp.text
    purchase_data = create_resp.json()
    purchase_id = purchase_data["id"]
    assert purchase_data["include_condiments_envelope"] is False
    assert purchase_data["total_budget_xof"] == 40000

    # 3. Validation de l'achat d'appoint avec déduction caisse
    complete_resp = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/complete?deduct_from_cash_session=true",
        headers=headers,
    )
    assert complete_resp.status_code == 200, complete_resp.text
    assert complete_resp.json()["status"] == "VALIDATED"

    # D9 : le stock n'entre qu'à la réception (quantités prévues par défaut)
    receive_resp = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/receive", headers=headers, json={}
    )
    assert receive_resp.status_code == 200, receive_resp.text
    assert receive_resp.json()["status"] == "COMPLETED"

    # Vérification : le stock de boeuf a augmenté de 10 kg
    db_session.expire_all()
    art_after = db_session.query(StockArticle).filter(StockArticle.id == art.id).first()
    assert art_after is not None
    assert art_after.quantity == Decimal("15")

    # Vérification : AUCUN condiment type (ex: Oignon violet) n'a été injecté
    from datetime import date as dt_date

    from caisse.models.finance import CashExpense

    expenses = db_session.query(CashExpense).filter(CashExpense.business_date == dt_date(2026, 11, 2)).all()
    # Le montant décaissé doit être STRICTEMENT de 40 000 XOF (et non 160 000 XOF)
    assert len(expenses) == 1
    assert expenses[0].amount_xof == 40000
    assert "condiments" not in expenses[0].reason

    # 4. Maintenant, test d'un Grand Marché Hebdo avec condiments (120 000 XOF)
    create_hebdo = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-11-03",
            "notes": "Grand marché hebdo",
            "include_condiments_envelope": True,
            "items": [{"article_id": str(art.id), "quantity": 5, "unit_price_xof": 4000}],
        },
    )
    assert create_hebdo.status_code == 201
    hebdo_data = create_hebdo.json()
    assert hebdo_data["include_condiments_envelope"] is True
    assert hebdo_data["total_budget_xof"] == 20000

    # Toggle test : mise à jour du bon (ex: patron désactive puis réactive)
    update_resp = client.put(
        f"/api/v1/production/market-purchases/{hebdo_data['id']}",
        headers=headers,
        json={"include_condiments_envelope": False},
    )
    assert update_resp.status_code == 200
    assert update_resp.json()["include_condiments_envelope"] is False

    # Réactiver le forfait condiments
    update_resp2 = client.put(
        f"/api/v1/production/market-purchases/{hebdo_data['id']}",
        headers=headers,
        json={"include_condiments_envelope": True},
    )
    assert update_resp2.status_code == 200
    assert update_resp2.json()["include_condiments_envelope"] is True

    # Valider le grand marché hebdo
    complete_hebdo = client.post(
        f"/api/v1/production/market-purchases/{hebdo_data['id']}/complete?deduct_from_cash_session=true",
        headers=headers,
    )
    assert complete_hebdo.status_code == 200
    assert client.post(
        f"/api/v1/production/market-purchases/{hebdo_data['id']}/receive", headers=headers, json={}
    ).status_code == 200

    # Vérification : Décaissement = 20 000 + 120 000 = 140 000 XOF
    db_session.expire_all()
    expenses_hebdo = db_session.query(CashExpense).filter(CashExpense.business_date == dt_date(2026, 11, 3)).all()
    assert len(expenses_hebdo) == 1
    assert expenses_hebdo[0].amount_xof == 140000

