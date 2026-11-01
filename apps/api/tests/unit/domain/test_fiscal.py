from caisse.domain.fiscal import (
    build_fne_payload,
    generate_fne_number,
    generate_fne_token,
    generate_qr_url,
)
from caisse.infrastructure.fne.mock import MockFneProvider


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


def test_mock_fne_provider_sign_and_refund():
    provider = MockFneProvider(ncc="2104598B", balance_sticker=100)
    payload = {
        "invoiceType": "sale",
        "paymentMethod": "cash",
        "template": "B2C",
        "items": [{"description": "Bissap", "quantity": 1, "amount": 1000, "taxes": ["TVA"]}],
    }
    result = provider.sign(payload, timeout=4.0)
    assert result.external_number.startswith("2104598B")
    assert result.qr_payload.startswith("mock://fne/verification/")
    assert result.amount_ttc == 1180
    assert result.invoice_id is not None
    assert provider.balance_sticker == 99

    # Test refund
    refund_result = provider.refund(
        result.invoice_id,
        {"items": [{"id": result.items[0].id, "quantity": 1}]},
        timeout=4.0,
    )
    assert refund_result.external_number.startswith("A2104598B")
    assert provider.balance_sticker == 98
