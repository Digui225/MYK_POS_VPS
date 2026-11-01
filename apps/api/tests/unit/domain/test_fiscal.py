import pytest

from caisse.domain.fiscal import (
    build_fne_payload,
    generate_fne_number,
    generate_fne_token,
    generate_qr_url,
)
from caisse.infrastructure.fne.manual_provider import ManualFneProvider
from caisse.infrastructure.fne.mock_provider import MockFneProvider


def test_generate_fne_number():
    fne_num = generate_fne_number("2026-09-28", 42, ncc="2104598B")
    assert fne_num == "FNE-2104598B-20260928-00042"


def test_generate_fne_token():
    payload_bytes = b'{"test": 123}'
    token = generate_fne_token(payload_bytes)
    assert len(token) == 32
    assert isinstance(token, str)


def test_generate_qr_url():
    url = generate_qr_url("FNE-2104598B-20260928-00042", "abcd1234efgh5678")
    assert url == "https://fne.dgi.gouv.ci/verify/FNE-2104598B-20260928-00042?token=abcd1234efgh5678"


def test_build_fne_payload():
    seller = {
        "name": "RESTAURANT MYK",
        "ncc": "2104598B",
        "rccm": "CI-ABJ-2024-B-12345",
        "tax_regime": "REEL_NORMAL",
        "address": "Abidjan Plateau",
    }
    buyer = {
        "name": "SOCIETE CIVILE IMMOBILIERE",
        "ncc": "9876543A",
        "phone": "+2250701020304",
        "email": "contact@sci.ci",
    }
    items = [
        {
            "name": "Bissap Frais",
            "category": "Boissons",
            "quantity": 2,
            "unit_price_xof": 1500,
            "line_total_xof": 3000,
            "vat_rate": 18.0,
        }
    ]
    payments = [
        {"method": "CASH", "amount_xof": 3000}
    ]
    totals = {
        "total_ht_xof": 2542,
        "total_vat_xof": 458,
        "total_ttc_xof": 3000,
    }

    payload = build_fne_payload(
        seller_info=seller,
        order_number="CMD-20260928-001",
        items=items,
        payments=payments,
        totals=totals,
        buyer_info=buyer,
    )

    assert payload["seller"]["ncc"] == "2104598B"
    assert payload["buyer"]["name"] == "SOCIETE CIVILE IMMOBILIERE"
    assert payload["buyer"]["ncc"] == "9876543A"
    assert len(payload["items"]) == 1
    assert payload["items"][0]["total_ttc_xof"] == 3000
    assert payload["totals"]["total_ttc_xof"] == 3000
    assert payload["document_type"] == "FNE"
    assert payload["schema_version"] == "1.0-CI-DGI"


@pytest.mark.anyio
async def test_mock_fne_provider_success():
    provider = MockFneProvider(should_fail=False)
    payload = {"invoice_number": "FNE-2104598B-20260928-00001", "totals": {"total_ttc_xof": 5000}}
    res = await provider.submit_invoice(payload)
    assert res.success is True
    assert res.status == "CERTIFIED"
    assert res.token is not None
    assert "https://fne.dgi.gouv.ci" in res.qr_url


@pytest.mark.anyio
async def test_mock_fne_provider_failure():
    provider = MockFneProvider(should_fail=True)
    payload = {"invoice_number": "FNE-2104598B-20260928-00001"}
    res = await provider.submit_invoice(payload)
    assert res.success is False
    assert res.status == "FAILED"
    assert res.error_message == "Simulated DGI server failure"


@pytest.mark.anyio
async def test_manual_fne_provider():
    provider = ManualFneProvider()
    payload = {"invoice_number": "FNE-2104598B-20260928-00002"}
    res = await provider.submit_invoice(payload)
    assert res.success is True
    assert res.status == "MANUAL_EXPORTED"
    assert res.token is not None
