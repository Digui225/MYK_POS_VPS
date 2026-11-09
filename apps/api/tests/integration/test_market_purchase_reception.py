"""Réception des bons d'achat marché (D9) : la validation ne touche pas le stock, seules les
quantités réellement reçues y entrent ; une erreur constatée plus tard se corrige par un
mouvement d'achat signé et tracé, et le stock de départ d'une semaine se corrige à côté.
D13 : le stock entre au jour de la réception (le bon se prépare souvent la veille du marché)."""

from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.errors import ValidationError
from caisse.models.audit import AuditLog
from caisse.models.production import MarketPurchaseList
from caisse.models.stock import StockArticle, StockMovement
from caisse.services import production_service
from caisse.services.production_service import get_weekly_matrix, redate_market_reception

BON_DATE = "2026-10-30"


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}


def _protein(db: Session, name: str, qty: int, cost: int) -> str:
    art = StockArticle(
        name=name, category="PROTEINE", unit="pièce", out_mode="RECIPE",
        quantity=Decimal(0), avg_cost_xof=Decimal(cost), is_active=True,
    )
    db.add(art)
    db.commit()
    return str(art.id)


def _count(client: TestClient, resp: dict[str, str], key: str, day: str, aid: str, qty: int) -> None:
    res = client.post(
        "/api/v1/stock/counts",
        headers={**resp, "Idempotency-Key": key},
        json={"business_date": day, "lines": [{"article_id": aid, "counted_quantity": qty}]},
    )
    assert res.status_code == 201, res.text


def _bon(client: TestClient, headers: dict[str, str], lines: list[tuple[str, int, int]]) -> dict:  # type: ignore[type-arg]
    res = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": BON_DATE,
            "items": [
                {"article_id": aid, "quantity": q, "unit_price_xof": p} for aid, q, p in lines
            ],
        },
    )
    assert res.status_code == 201, res.text
    return res.json()  # type: ignore[no-any-return]


def _stock(db: Session, aid: str) -> Decimal:
    db.expire_all()
    art = db.get(StockArticle, aid)
    assert art is not None
    return Decimal(art.quantity)


def _receive_on(monkeypatch: pytest.MonkeyPatch, day: str) -> None:
    """Fixe le jour de la réception (sinon : la journée de la caisse ouverte, ou aujourd'hui)."""
    monkeypatch.setattr(production_service, "_reception_day", lambda _db: date.fromisoformat(day))


def test_reception_puis_correction_des_quantites_recues(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    _receive_on(monkeypatch, BON_DATE)
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")
    brochet = _protein(db_session, "Brochet", 0, 800)
    sosso = _protein(db_session, "Sosso", 0, 1540)
    _count(client, resp, "c-b", "2026-10-26", brochet, 6)
    _count(client, resp, "c-s", "2026-10-26", sosso, 6)

    bon = _bon(client, caissier, [(brochet, 24, 800), (sosso, 7, 1540)])
    items = {i["article_id"]: i["id"] for i in bon["items"]}
    url = f"/api/v1/production/market-purchases/{bon['id']}"

    # Réception refusée avant validation
    assert client.post(f"{url}/receive", headers=resp, json={}).status_code == 422

    # Validation : argent remis, le stock ne bouge pas
    validated = client.post(f"{url}/complete", headers=resp)
    assert validated.status_code == 200, validated.text
    assert validated.json()["status"] == "VALIDATED"
    assert _stock(db_session, brochet) == 6
    assert _stock(db_session, sosso) == 6

    # Caissier non autorisé à réceptionner
    assert client.post(f"{url}/receive", headers=caissier, json={}).status_code == 403

    # Réception : 26 brochets reçus (24 prévus) ; Sosso absente du corps = quantité prévue
    rec = client.post(
        f"{url}/receive",
        headers=resp,
        json={"lines": [{"item_id": items[brochet], "received_quantity": 26}]},
    )
    assert rec.status_code == 200, rec.text
    body = rec.json()
    assert body["status"] == "COMPLETED"
    assert body["received_by_user_name"]
    received = {i["article_id"]: i["received_quantity"] for i in body["items"]}
    assert received == {brochet: 26.0, sosso: 7.0}
    assert _stock(db_session, brochet) == 32
    assert _stock(db_session, sosso) == 13
    movement = (
        db_session.query(StockMovement)
        .filter(StockMovement.article_id == brochet, StockMovement.type == "PURCHASE_IN")
        .one()
    )
    assert movement.business_date == date(2026, 10, 30)  # jour de la réception
    assert movement.quantity == 26

    # Correction : la Sosso reçue était de 5, pas 7 ; motif obligatoire
    fix = {"lines": [{"item_id": items[sosso], "received_quantity": 5}]}
    assert client.post(f"{url}/receive", headers=resp, json=fix).status_code == 422
    fix["reason"] = "Recompte au retour du marché"  # type: ignore[assignment]
    res = client.post(f"{url}/receive", headers=resp, json=fix)
    assert res.status_code == 200, res.text
    assert {i["article_id"]: i["received_quantity"] for i in res.json()["items"]}[sosso] == 5.0
    assert _stock(db_session, sosso) == 11
    correction = (
        db_session.query(StockMovement)
        .filter(StockMovement.article_id == sosso, StockMovement.quantity < 0)
        .one()
    )
    assert correction.type == "PURCHASE_IN"
    assert correction.business_date == date(2026, 10, 30)
    assert "7 → 5" in (correction.reason or "")

    # Rejouer la même correction ne change rien (valeurs cibles)
    assert client.post(f"{url}/receive", headers=resp, json=fix).status_code == 200
    assert _stock(db_session, sosso) == 11
    assert (
        db_session.query(StockMovement)
        .filter(StockMovement.article_id == sosso, StockMovement.type == "PURCHASE_IN")
        .count()
        == 2
    )

    # Matrice de la semaine : 6 stk + 5 ach pour la Sosso, 6 + 26 pour le brochet
    matrix = get_weekly_matrix(db_session, date(2026, 10, 27), date(2026, 11, 2))
    rows = {r.article_id: r for r in matrix.rows}
    assert (rows[sosso].opening_stock_qty, rows[sosso].weekly_purchased_qty) == (6.0, 5.0)
    assert rows[sosso].total_available_qty == 11.0
    assert (rows[brochet].opening_stock_qty, rows[brochet].weekly_purchased_qty) == (6.0, 26.0)


def test_correction_du_stock_initial(client: TestClient, db_session: Session) -> None:
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")
    loss = _protein(db_session, "Loss", 0, 556)
    _count(client, resp, "c-l", "2026-10-26", loss, 4)

    body = {
        "article_id": loss,
        "business_date": "2026-10-27",
        "quantity": 6,
        "reason": "Comptage du lundi matin",
    }
    assert (
        client.post("/api/v1/production/opening-stock-corrections", headers=caissier, json=body)
        .status_code
        == 403
    )
    res = client.post("/api/v1/production/opening-stock-corrections", headers=resp, json=body)
    assert res.status_code == 200, res.text
    out = res.json()
    assert (out["previous_quantity"], out["quantity"], out["delta_quantity"]) == (4.0, 6.0, 2.0)
    assert out["current_stock_quantity"] == 6.0

    matrix = get_weekly_matrix(db_session, date(2026, 10, 27), date(2026, 11, 2))
    row = next(r for r in matrix.rows if r.article_id == loss)
    assert row.opening_stock_qty == 6.0
    assert row.closing_stock_qty == row.current_stock_qty == 6.0

    # Valeur cible : rejouer ne crée pas de nouveau mouvement
    again = client.post("/api/v1/production/opening-stock-corrections", headers=resp, json=body)
    assert again.json()["delta_quantity"] == 0.0
    assert (
        db_session.query(StockMovement)
        .filter(StockMovement.article_id == loss, StockMovement.type == "OPENING")
        .count()
        == 2
    )


def test_le_stock_entre_au_jour_de_la_reception_et_se_recale(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bon préparé le vendredi 30/10, marché et réception le lundi 02/11 : les achats comptent
    dans la semaine du lundi, corrections comprises."""
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")
    brochet = _protein(db_session, "Brochet", 0, 800)
    _count(client, resp, "c-b", "2026-10-26", brochet, 3)

    bon = _bon(client, caissier, [(brochet, 25, 800)])
    item = bon["items"][0]["id"]
    url = f"/api/v1/production/market-purchases/{bon['id']}"
    assert client.post(f"{url}/complete", headers=resp).status_code == 200

    _receive_on(monkeypatch, "2026-11-02")
    rec = client.post(f"{url}/receive", headers=resp, json={})
    assert rec.status_code == 200, rec.text
    assert (rec.json()["business_date"], rec.json()["stock_date"]) == (BON_DATE, "2026-11-02")

    # Correction faite plus tard : datée comme la réception, pas comme le jour de la correction
    _receive_on(monkeypatch, "2026-11-04")
    fix = {"lines": [{"item_id": item, "received_quantity": 24}], "reason": "Un brochet abîmé"}
    assert client.post(f"{url}/receive", headers=resp, json=fix).status_code == 200
    dates = {
        m.business_date
        for m in db_session.query(StockMovement).filter(
            StockMovement.article_id == brochet, StockMovement.type == "PURCHASE_IN"
        )
    }
    assert dates == {date(2026, 11, 2)}

    friday_week = get_weekly_matrix(db_session, date(2026, 10, 26), date(2026, 10, 30))
    monday_week = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    assert friday_week.total_weekly_purchases_xof == 0
    assert monday_week.total_weekly_purchases_xof == 24 * 800
    row = next(r for r in monday_week.rows if r.article_id == brochet)
    assert (row.opening_stock_qty, row.weekly_purchased_qty) == (3.0, 24.0)


def test_recalage_d_un_bon_recu_a_la_date_du_bon(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bon réceptionné avant D13 (stock entré à la date du bon, vendredi) : le recalage déplace
    ses achats au lundi par un retrait et une entrée tracés ; stock et coût moyen inchangés."""
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")
    brochet = _protein(db_session, "Brochet", 0, 800)
    _count(client, resp, "c-b", "2026-10-26", brochet, 3)
    bon = _bon(client, caissier, [(brochet, 25, 1000)])
    url = f"/api/v1/production/market-purchases/{bon['id']}"
    assert client.post(f"{url}/complete", headers=resp).status_code == 200
    _receive_on(monkeypatch, BON_DATE)
    assert client.post(f"{url}/receive", headers=resp, json={}).status_code == 200

    db_session.expire_all()
    before = db_session.get(StockArticle, brochet)
    assert before is not None
    stock_before, cost_before = before.quantity, before.avg_cost_xof

    with pytest.raises(ValidationError):
        redate_market_reception(db_session, bon["id"], date(2026, 11, 2), user_id="usr-admin-01", reason="")
    moves = redate_market_reception(
        db_session, bon["id"], date(2026, 11, 2), user_id="usr-admin-01", reason="Marché fait le lundi"
    )
    assert moves == [{"article": "Brochet", "quantity": "25"}]
    # Rejouer ne refait rien
    assert redate_market_reception(
        db_session, bon["id"], date(2026, 11, 2), user_id="usr-admin-01", reason="Marché fait le lundi"
    ) == []

    db_session.expire_all()
    after = db_session.get(StockArticle, brochet)
    assert after is not None
    assert (after.quantity, after.avg_cost_xof) == (stock_before, cost_before)
    purchase = db_session.get(MarketPurchaseList, bon["id"])
    assert purchase is not None and purchase.stock_date == date(2026, 11, 2)
    signed = sorted(
        (m.business_date, m.quantity)
        for m in db_session.query(StockMovement).filter(
            StockMovement.article_id == brochet, StockMovement.type == "PURCHASE_IN"
        )
    )
    assert signed == [(date(2026, 10, 30), -25), (date(2026, 10, 30), 25), (date(2026, 11, 2), 25)]
    assert db_session.query(AuditLog).filter(AuditLog.action == "market_purchase.reception_redated").count() == 1

    friday_week = get_weekly_matrix(db_session, date(2026, 10, 26), date(2026, 10, 30))
    monday_week = get_weekly_matrix(db_session, date(2026, 11, 2), date(2026, 11, 6))
    assert friday_week.total_weekly_purchases_xof == 0
    assert monday_week.total_weekly_purchases_xof == 25 * 1000
