"""Total versé sans fond de caisse et régularisation d'un écart de caisse après la clôture :
le Z ne change pas, la régularisation est tracée à côté et entre dans le total versé."""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.cash_session import CashSession

DAY = "2026-11-09"


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}


def _open(client: TestClient, headers: dict[str, str], day: str = DAY) -> str:
    res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": f"sess-{uuid.uuid4()}"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 10000, "business_date": day},
    )
    assert res.status_code == 201, res.text
    return str(res.json()["id"])


def _sell_wave_and_cash(client: TestClient, headers: dict[str, str]) -> None:
    """Une commande de 10 000 : 4 000 en Wave, 6 000 en espèces."""
    oid = client.post(
        "/api/v1/orders", headers=headers, json={"table_id": "tbl-01", "guests_count": 1}
    ).json()["id"]
    res = client.post(
        f"/api/v1/orders/{oid}/items",
        headers=headers,
        json={"custom_name": "Plat du jour", "unit_price_xof": 10000, "quantity": 1},
    )
    assert res.status_code in (200, 201), res.text
    for method, amount, extra in (
        ("MOBILE_MONEY", 4000, {"provider": "Wave", "reference": "WAVE-1"}),
        ("CASH", 6000, {"tendered_xof": 6000}),
    ):
        pay = client.post(
            f"/api/v1/orders/{oid}/payments",
            headers={**headers, "Idempotency-Key": f"pay-{uuid.uuid4()}"},
            json={"method": method, "amount_xof": amount, **extra},
        )
        assert pay.status_code == 201, pay.text


def _close_with_shortage(client: TestClient, headers: dict[str, str], session_id: str) -> None:
    """Attendu 16 000 (fond 10 000 + espèces 6 000), compté 14 000 : écart −2 000."""
    res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": f"close-{session_id}"},
        json={"counted_breakdown": {"10000": 1, "2000": 2}},
    )
    assert res.status_code == 200, res.text


def _day(client: TestClient, headers: dict[str, str]) -> dict:  # type: ignore[type-arg]
    report = client.get(
        "/api/v1/reports/sales", headers=headers, params={"date_from": DAY, "date_to": DAY}
    ).json()
    return {"day": report["by_day"][0], "totals": report["totals"], "sessions": report["cash_sessions"]}


def test_total_verse_sans_fond_de_caisse_puis_regularisation(
    client: TestClient, db_session: Session
) -> None:
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")

    sid = _open(client, caissier)
    _sell_wave_and_cash(client, caissier)
    _close_with_shortage(client, caissier, sid)

    before = _day(client, resp)
    d = before["day"]
    assert d["revenue_xof"] == 10000
    assert d["counted_cash_xof"] == 14000  # champ historique : fond inclus
    assert d["opening_float_xof"] == 10000
    assert d["non_cash_payments_xof"] == 4000
    assert d["cash_variance_xof"] == -2000
    # Total versé = 14 000 − 10 000 (fond) + 4 000 (Wave) = 8 000 = CA − écart
    assert d["remitted_xof"] == 8000
    assert d["adjusted_cash_variance_xof"] == -2000
    assert d["has_closed_session"] is True

    # Les 2 000 sont retrouvés : régularisation (clé d'idempotence obligatoire)
    body = {"business_date": DAY, "amount_xof": 2000, "reason": "Manque retrouvé dans le coffre"}
    no_key = client.post("/api/v1/finance/cash-regularizations", headers=resp, json=body)
    assert no_key.status_code == 400, no_key.text
    headers = {**resp, "Idempotency-Key": "reg-1"}
    res = client.post("/api/v1/finance/cash-regularizations", headers=headers, json=body)
    assert res.status_code == 201, res.text
    reg = res.json()
    assert reg["cash_session_id"] == sid
    assert reg["amount_xof"] == 2000
    assert reg["z_number"] is not None
    replay = client.post("/api/v1/finance/cash-regularizations", headers=headers, json=body)
    assert replay.status_code == 200  # rejeu de la réponse d'origine
    assert replay.json()["id"] == reg["id"]

    after = _day(client, resp)
    d = after["day"]
    assert d["cash_regularization_xof"] == 2000
    assert d["adjusted_cash_variance_xof"] == 0
    assert d["remitted_xof"] == 10000  # = chiffre d'affaires
    assert d["cash_variance_xof"] == -2000  # l'écart du Z ne change pas
    assert after["totals"]["remitted_xof"] == 10000
    assert after["totals"]["cash_regularization_xof"] == 2000
    assert after["sessions"][0]["regularization_xof"] == 2000
    assert after["sessions"][0]["opening_float_xof"] == 10000

    # Le Z clôturé n'est pas modifié
    session = db_session.get(CashSession, sid)
    assert session is not None
    db_session.refresh(session)
    assert session.variance_xof == -2000

    listing = client.get(
        "/api/v1/finance/cash-regularizations",
        headers=resp,
        params={"date_from": DAY, "date_to": DAY},
    ).json()
    assert listing["total_count"] == 1
    assert listing["total_amount_xof"] == 2000


def test_regularisation_refusee_hors_journee_cloturee(client: TestClient) -> None:
    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")

    def post(body: dict, key: str, headers: dict[str, str] = resp):  # type: ignore[no-untyped-def,type-arg]
        return client.post(
            "/api/v1/finance/cash-regularizations",
            headers={**headers, "Idempotency-Key": key},
            json=body,
        )

    # Aucune session ce jour-là
    res = post({"business_date": DAY, "amount_xof": 500, "reason": "Test"}, "k1")
    assert res.status_code == 422, res.text

    # Session encore ouverte : on corrige au comptage, pas par régularisation
    _open(client, caissier)
    res = post({"business_date": DAY, "amount_xof": 500, "reason": "Test"}, "k2")
    assert res.status_code == 422, res.text

    # Montant nul refusé ; caissier non autorisé
    assert post({"business_date": DAY, "amount_xof": 0, "reason": "Test"}, "k3").status_code == 422
    res = post({"business_date": DAY, "amount_xof": 500, "reason": "Test"}, "k4", caissier)
    assert res.status_code == 403, res.text
