"""Rapport de ventes PDF envoyé par mail à chaque clôture de caisse (outbox DAILY_REPORT_EMAIL)."""

from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.infrastructure.mail import OutgoingMail
from caisse.infrastructure.outbox.dispatcher import dispatch_pending_outbox_events
from caisse.models.outbox import OutboxEvent
from caisse.services import daily_report_mail_service

DEVICE = "pos-terminal-01"


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post("/api/v1/auth/login", json={"pin": pin, "device_id": DEVICE}).json()[
        "access_token"
    ]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": DEVICE}


@pytest.fixture
def smtp_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    settings = get_settings()
    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.test.local")
    monkeypatch.setattr(settings, "SMTP_FROM", "rapports@caisse.osispos.com")


@pytest.fixture
def sent(monkeypatch: pytest.MonkeyPatch) -> list[OutgoingMail]:
    """Mails « envoyés » (aucun vrai envoi SMTP en test)."""
    outbox: list[OutgoingMail] = []
    monkeypatch.setattr(daily_report_mail_service, "send_mail", outbox.append)
    return outbox


def _set_recipients(client: TestClient, emails: list[str]) -> Any:
    admin = _headers(client, "999999")
    return client.put("/api/v1/settings", headers=admin, json={"report_email_recipients": emails})


def _sell_and_close(client: TestClient) -> tuple[str, int]:
    """Ouvre la caisse, vend un plat de 8 000 XOF payé en espèces, clôture ; (session, n° de Z)."""
    resp = _headers(client, "654321")
    cat_id = client.post(
        "/api/v1/catalog/categories", headers=resp, json={"name": "Grillades", "kind": "FOOD"}
    ).json()["id"]
    prod_id = client.post(
        "/api/v1/catalog/products",
        headers=resp,
        json={"category_id": cat_id, "name": "Bœuf braisé", "short_name": "BOEUF", "price_xof": 8000},
    ).json()["id"]

    cashier = _headers(client, "123456")
    session_id = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "mail-sess-open"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 0, "business_date": "2026-11-12"},
    ).json()["id"]
    order = client.post(
        "/api/v1/orders", headers=cashier, json={"table_id": "tbl-01", "guests_count": 1}
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    item = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=cashier,
        json={"product_id": prod_id, "quantity": 1},
    )
    assert item.status_code in (200, 201), item.text
    pay = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cashier, "Idempotency-Key": "mail-pay"},
        json={"method": "CASH", "amount_xof": 8000, "tendered_xof": 8000},
    )
    assert pay.status_code in (200, 201), pay.text
    close = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**cashier, "Idempotency-Key": "mail-sess-close"},
        json={"counted_breakdown": {"5000": 1, "2000": 1, "1000": 1}},
    )
    assert close.status_code == 200, close.text
    return session_id, close.json()["z_number"]


def _report_events(db: Session) -> list[OutboxEvent]:
    db.expire_all()
    return db.query(OutboxEvent).filter(OutboxEvent.event_type == "DAILY_REPORT_EMAIL").all()


def test_recipients_are_set_in_settings_and_validated(client: TestClient) -> None:
    res = _set_recipients(client, [" M.Yapi@Example.com ", "patron@example.com", "m.yapi@example.com"])
    assert res.status_code == 200, res.text
    assert res.json()["report_email_recipients"] == ["m.yapi@example.com", "patron@example.com"]

    got = client.get("/api/v1/settings", headers=_headers(client, "654321")).json()
    assert got["report_email_recipients"] == ["m.yapi@example.com", "patron@example.com"]
    assert got["report_email_enabled"] is False  # pas de SMTP en test

    bad = _set_recipients(client, ["pas-une-adresse"])
    assert bad.status_code == 422
    assert bad.json()["code"] == "INVALID_EMAIL"


def test_closing_sends_the_daily_report_pdf(
    client: TestClient, db_session: Session, smtp_configured: None, sent: list[OutgoingMail]
) -> None:
    assert _set_recipients(client, ["m.yapi@example.com"]).status_code == 200
    session_id, z_number = _sell_and_close(client)

    events = _report_events(db_session)
    assert len(events) == 1
    assert events[0].aggregate_id == session_id
    assert events[0].payload["business_date"] == "2026-11-12"
    assert not sent  # la clôture n'attend pas le mail : c'est l'outbox qui l'envoie

    dispatch_pending_outbox_events(db_session)

    assert len(sent) == 1
    mail = sent[0]
    assert mail.to == ["m.yapi@example.com"]
    assert mail.subject == f"Rapport de ventes — jeudi 12 novembre 2026 — Z n° {z_number}"
    assert "Chiffre d'affaires : 8 000 FCFA" in mail.text
    assert f"Z n° {z_number} — écart de caisse : 0 FCFA" in mail.text
    [pdf] = mail.attachments
    assert pdf.filename == "Rapport_Ventes_2026-11-12.pdf"
    assert pdf.content.startswith(b"%PDF")
    assert _report_events(db_session)[0].status == "COMPLETED"


def test_no_mail_without_recipients_or_smtp(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    # SMTP non configuré : rien n'est programmé, même avec un destinataire
    assert _set_recipients(client, ["m.yapi@example.com"]).status_code == 200
    _sell_and_close(client)
    assert _report_events(db_session) == []


def test_closing_without_recipient_programs_nothing(
    client: TestClient, db_session: Session, smtp_configured: None
) -> None:
    _sell_and_close(client)
    assert _report_events(db_session) == []


def test_failed_send_is_retried_by_the_outbox(
    client: TestClient, db_session: Session, smtp_configured: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    def refuse(_mail: OutgoingMail) -> None:
        raise ConnectionError("relais SMTP injoignable")

    monkeypatch.setattr(daily_report_mail_service, "send_mail", refuse)
    assert _set_recipients(client, ["m.yapi@example.com"]).status_code == 200
    _sell_and_close(client)

    dispatch_pending_outbox_events(db_session)

    [event] = _report_events(db_session)
    assert event.status == "PENDING"
    assert event.retry_count == 1
    assert event.next_retry_at is not None
    assert "injoignable" in (event.last_error or "")


def test_manual_send_endpoint(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch, sent: list[OutgoingMail]
) -> None:
    resp = _headers(client, "654321")
    url = "/api/v1/reports/daily-sales/email?business_date=2026-11-12"

    not_configured = client.post(url, headers=resp)
    assert not_configured.status_code == 409
    assert not_configured.json()["code"] == "MAIL_NOT_CONFIGURED"

    settings = get_settings()
    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.test.local")
    monkeypatch.setattr(settings, "SMTP_FROM", "rapports@caisse.osispos.com")
    no_recipient = client.post(url, headers=resp)
    assert no_recipient.status_code == 409
    assert no_recipient.json()["code"] == "NO_REPORT_RECIPIENTS"

    assert _set_recipients(client, ["m.yapi@example.com"]).status_code == 200
    ok = client.post(url, headers={**resp, "Idempotency-Key": "mail-manual-1"})
    assert ok.status_code == 200, ok.text
    assert ok.json() == {"business_date": "2026-11-12", "recipients": ["m.yapi@example.com"], "queued": True}
    replay = client.post(url, headers={**resp, "Idempotency-Key": "mail-manual-1"})
    assert replay.headers.get("Idempotent-Replay") == "true"
    assert len(_report_events(db_session)) == 1

    cashier = _headers(client, "123456")
    assert client.post(url, headers=cashier).status_code == 403

    dispatch_pending_outbox_events(db_session)
    assert len(sent) == 1
    assert sent[0].subject == "Rapport de ventes — jeudi 12 novembre 2026"
    assert "Aucune" not in sent[0].text
