"""Annulation des bons d'achat marché (D10) : seul un bon pas encore validé s'annule, avec un
motif ; le bon reste dans l'historique ; l'économe n'annule que ses propres bons."""

from decimal import Decimal

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.models.audit import AuditLog
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.user import User

URL = "/api/v1/production/market-purchases"


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}


def _setup(db: Session) -> str:
    db.add_all(
        [
            User(full_name="Kady Économe", pin_hash=hash_pin("112233"), role="ECONOME", is_active=True),
            User(full_name="Awa Économe", pin_hash=hash_pin("445566"), role="ECONOME", is_active=True),
        ]
    )
    sosso = StockArticle(
        name="Sosso", category="PROTEINE", unit="pièce", out_mode="RECIPE",
        quantity=Decimal(0), avg_cost_xof=Decimal(1594), is_active=True,
    )
    db.add(sosso)
    db.commit()
    return str(sosso.id)


def _bon(client: TestClient, headers: dict[str, str], aid: str) -> str:
    res = client.post(
        URL,
        headers=headers,
        json={
            "business_date": "2026-11-05",
            "items": [{"article_id": aid, "quantity": 12, "unit_price_xof": 1594}],
        },
    )
    assert res.status_code == 201, res.text
    return str(res.json()["id"])


def test_annulation_bon_en_attente(client: TestClient, db_session: Session) -> None:
    sosso = _setup(db_session)
    econome = _headers(client, "112233")
    resp = _headers(client, "654321")
    bon = _bon(client, econome, sosso)

    # Motif obligatoire
    assert client.post(f"{URL}/{bon}/cancel", headers=resp, json={}).status_code == 422
    assert (
        client.post(f"{URL}/{bon}/cancel", headers=resp, json={"reason": "  "}).status_code
        == 422
    )

    res = client.post(f"{URL}/{bon}/cancel", headers=resp, json={"reason": "Bon saisi en double"})
    assert res.status_code == 200, res.text
    out = res.json()
    assert out["status"] == "CANCELLED"
    assert out["cancel_reason"] == "Bon saisi en double"
    assert out["cancelled_by_user_name"]
    assert out["cancelled_at"] is not None

    # Rejouer ne change rien
    again = client.post(f"{URL}/{bon}/cancel", headers=resp, json={"reason": "Autre motif"})
    assert again.status_code == 200
    assert again.json()["cancel_reason"] == "Bon saisi en double"

    # Le bon reste dans la liste (historique), et ne peut plus être validé, modifié ni réceptionné
    listed = {p["id"]: p for p in client.get(URL, headers=resp).json()}
    assert listed[bon]["status"] == "CANCELLED"
    assert client.post(f"{URL}/{bon}/complete", headers=resp).status_code == 422
    assert client.post(f"{URL}/{bon}/receive", headers=resp, json={}).status_code == 422
    assert (
        client.put(f"{URL}/{bon}", headers=resp, json={"notes": "x"}).status_code == 400
    )

    # Aucun effet sur le stock, annulation tracée
    db_session.expire_all()
    assert db_session.query(StockMovement).filter(StockMovement.article_id == sosso).count() == 0
    assert (
        db_session.query(AuditLog)
        .filter(AuditLog.action == "market_purchase.cancel", AuditLog.entity_id == bon)
        .count()
        == 1
    )


def test_bon_valide_ou_receptionne_non_annulable(
    client: TestClient, db_session: Session
) -> None:
    sosso = _setup(db_session)
    resp = _headers(client, "654321")
    bon = _bon(client, resp, sosso)
    assert client.post(f"{URL}/{bon}/complete", headers=resp).status_code == 200

    res = client.post(f"{URL}/{bon}/cancel", headers=resp, json={"reason": "Erreur"})
    assert res.status_code == 409
    assert res.json()["code"] == "PURCHASE_NOT_CANCELLABLE"

    assert client.post(f"{URL}/{bon}/receive", headers=resp, json={}).status_code == 200
    res = client.post(f"{URL}/{bon}/cancel", headers=resp, json={"reason": "Erreur"})
    assert res.status_code == 409


def test_droits_annulation(client: TestClient, db_session: Session) -> None:
    sosso = _setup(db_session)
    kady = _headers(client, "112233")
    awa = _headers(client, "445566")
    caissier = _headers(client, "123456")
    admin = _headers(client, "999999")

    bon_kady = _bon(client, kady, sosso)
    bon_caissier = _bon(client, caissier, sosso)

    # Le caissier ne peut pas annuler, même son propre bon
    res = client.post(f"{URL}/{bon_caissier}/cancel", headers=caissier, json={"reason": "Erreur"})
    assert res.status_code == 403
    # Une économe ne peut pas annuler le bon d'une autre
    res = client.post(f"{URL}/{bon_kady}/cancel", headers=awa, json={"reason": "Erreur"})
    assert res.status_code == 403
    # L'économe annule son propre bon
    res = client.post(f"{URL}/{bon_kady}/cancel", headers=kady, json={"reason": "Erreur de saisie"})
    assert res.status_code == 200
    assert res.json()["status"] == "CANCELLED"
    # L'admin annule n'importe quel bon en attente
    res = client.post(f"{URL}/{bon_caissier}/cancel", headers=admin, json={"reason": "Doublon"})
    assert res.status_code == 200
