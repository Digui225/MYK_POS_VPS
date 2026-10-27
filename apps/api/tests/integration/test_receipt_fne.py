"""Bloc fiscal du ticket : jamais de numéro, de lien ou de signature inventés."""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.domain.enums import FneDocumentType, FneStatus
from caisse.domain.payment_rules import format_receipt_text
from caisse.domain.ports import FneUnavailableError
from caisse.models.fne import FneDocument
from caisse.models.print_job import PrintJob
from caisse.services.fne_service import receipt_fne_info

REAL_TOKEN = "https://www.services.fne.dgi.gouv.ci/fr/verification/abc123"


def _doc(**kw) -> FneDocument:
    base = dict(type=FneDocumentType.FNE, status=FneStatus.CERTIFIED, external_number="1304777N26000000023", qr_payload=REAL_TOKEN)
    return FneDocument(**{**base, **kw})


def test_only_a_certified_sale_fne_reaches_the_ticket() -> None:
    assert receipt_fne_info(_doc()) == {"fne_number": "1304777N26000000023", "qr_url": REAL_TOKEN, "simulated": False}
    assert receipt_fne_info(None) is None
    for status in (FneStatus.PENDING, FneStatus.QUEUED, FneStatus.SUBMITTING, FneStatus.FAILED, FneStatus.MANUAL):
        assert receipt_fne_info(_doc(status=status)) is None, status
    assert receipt_fne_info(_doc(type=FneDocumentType.REFUND)) is None
    assert receipt_fne_info(_doc(external_number=None)) is None


def test_qr_only_from_the_dgi_link() -> None:
    assert receipt_fne_info(_doc(qr_payload=None))["qr_url"] is None  # certification manuelle sans lien
    simulated = receipt_fne_info(_doc(qr_payload="mock://fne/verification/x"))
    assert simulated["qr_url"] is None and simulated["simulated"] is True


def _ticket(fne_info) -> str:
    return format_receipt_text(
        restaurant_info={"name": "RESTAURANT CHEZ SYLLA PLUS"},
        order_info={"order_number": "C-0001"},
        items=[],
        payments=[],
        totals={},
        fne_info=fne_info,
    )


def test_ticket_fiscal_block() -> None:
    real = _ticket(receipt_fne_info(_doc()))
    assert "FACTURE NORMALISEE DGI" in real and "1304777N26000000023" in real
    assert f"[QR_CODE: {REAL_TOKEN}]" in real
    assert "Signature DGI" not in real

    simulated = _ticket(receipt_fne_info(_doc(qr_payload="mock://fne/verification/x")))
    assert "SANS VALEUR FISCALE" in simulated and "FACTURE NORMALISEE DGI" not in simulated

    none = _ticket(None)
    assert "FNE" not in none and "DGI" not in none


def _pay_with_fne(client: TestClient, key: str) -> dict:
    resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-terminal-01"})
    resp_headers = {"Authorization": f"Bearer {resp.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}
    cat_id = client.post("/api/v1/catalog/categories", headers=resp_headers, json={"name": "Grillades", "kind": "FOOD"}).json()["id"]
    prod_id = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Poulet Braisé", "short_name": "POULET", "price_xof": 7000},
    ).json()["id"]
    login = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-terminal-01"})
    headers = {"Authorization": f"Bearer {login.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}
    client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": f"{key}-sess"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 25000, "business_date": "2026-09-28"},
    )
    order_id = client.post("/api/v1/orders", headers=headers, json={"table_id": "tbl-01", "guests_count": 1}).json()["id"]
    client.post(f"/api/v1/orders/{order_id}/items", headers=headers, json={"product_id": prod_id, "quantity": 1})
    pay = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": f"{key}-pay"},
        json={"method": "CASH", "amount_xof": 7000, "tendered_xof": 10000, "request_fne": True},
    )
    assert pay.status_code == 201, pay.text
    return {**pay.json(), "order_id": order_id}


def test_simulated_fne_is_labelled_on_the_ticket(client: TestClient, db_session: Session) -> None:
    pay = _pay_with_fne(client, "fne-sim")
    content = db_session.get(PrintJob, pay["print_job_id"]).content
    doc = db_session.query(FneDocument).filter(FneDocument.order_id == pay["order_id"]).one()

    assert doc.status == FneStatus.CERTIFIED
    assert doc.external_number in content
    assert "SANS VALEUR FISCALE" in content and "Signature DGI" not in content


def test_unavailable_dgi_prints_no_fiscal_block(
    client: TestClient, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    class DgiDown:
        def sign(self, payload, *, timeout):
            raise FneUnavailableError("connexion refusée")

        def refund(self, invoice_id, payload, *, timeout):
            raise FneUnavailableError("connexion refusée")

    monkeypatch.setattr("caisse.deps.get_fne_provider", lambda: DgiDown())
    pay = _pay_with_fne(client, "fne-down")
    content = db_session.get(PrintJob, pay["print_job_id"]).content
    doc = db_session.query(FneDocument).filter(FneDocument.order_id == pay["order_id"]).one()

    assert doc.status == FneStatus.QUEUED  # renvoyée plus tard par le worker
    assert "FNE" not in content and "DGI" not in content
