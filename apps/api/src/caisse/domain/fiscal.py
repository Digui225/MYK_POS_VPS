import hashlib
from datetime import datetime, timezone
from typing import Any

from caisse.domain.money import calculate_vat_split


def generate_fne_number(business_date_str: str, sequence: int, ncc: str = "2104598B") -> str:
    """Génère le numéro officiel de Facture Normalisée Électronique : FNE-2104598B-20260928-00042."""
    date_compact = business_date_str.replace("-", "")
    return f"FNE-{ncc}-{date_compact}-{sequence:05d}"


def generate_fne_token(payload_bytes: bytes) -> str:
    """Calcule l'empreinte cryptographique SHA-256 du payload normalisé."""
    return hashlib.sha256(payload_bytes).hexdigest()[:32]


def generate_qr_url(fne_number: str, token: str) -> str:
    """Génère l'URL officielle DGI pour le QR code de certification."""
    return f"https://fne.dgi.gouv.ci/verify/{fne_number}?token={token}"


def build_fne_payload(
    seller_info: dict[str, str],
    order_number: str,
    items: list[dict[str, Any]],
    payments: list[dict[str, Any]],
    totals: dict[str, int],
    buyer_info: dict[str, str | None] | None = None,
    document_type: str = "FNE",
    original_fne_number: str | None = None,
) -> dict[str, Any]:
    """Construit le payload normalisé DGI figé et immuable."""
    buyer = {
        "name": (buyer_info and buyer_info.get("name")) or "CLIENT PASSAGE",
        "ncc": buyer_info.get("ncc") if buyer_info else None,
        "phone": buyer_info.get("phone") if buyer_info else None,
        "email": buyer_info.get("email") if buyer_info else None,
    }

    fiscal_items = []
    for it in items:
        qty = it.get("quantity", 1)
        unit_price = it.get("unit_price_xof", 0)
        line_total = it.get("line_total_xof", unit_price * qty)
        vat_rate = it.get("vat_rate", 18.0)
        ht, vat = calculate_vat_split(line_total, vat_rate)

        fiscal_items.append({
            "name": it.get("name", "Article"),
            "category": it.get("category", "Menu"),
            "quantity": qty,
            "unit_price_xof": unit_price,
            "vat_rate": vat_rate,
            "total_ht_xof": ht,
            "total_vat_xof": vat,
            "total_ttc_xof": line_total,
        })

    fiscal_payments = []
    for p in payments:
        fiscal_payments.append({
            "method": p.get("method", "CASH"),
            "amount_xof": p.get("amount_xof", 0),
            "provider": p.get("provider"),
            "reference": p.get("reference"),
        })

    return {
        "document_type": document_type,
        "original_fne_number": original_fne_number,
        "seller": {
            "name": seller_info.get("name", "RESTAURANT MYK"),
            "ncc": seller_info.get("ncc", "2104598B"),
            "rccm": seller_info.get("rccm", "CI-ABJ-2024-B-12345"),
            "tax_regime": seller_info.get("tax_regime", "REEL_NORMAL"),
            "address": seller_info.get("address", "Abidjan, Côte d'Ivoire"),
        },
        "buyer": buyer,
        "order_reference": order_number,
        "items": fiscal_items,
        "totals": {
            "total_ht_xof": totals.get("total_ht_xof", 0),
            "total_vat_xof": totals.get("total_vat_xof", 0),
            "total_ttc_xof": totals.get("total_ttc_xof", 0),
        },
        "payments": fiscal_payments,
        "issued_at": datetime.now(timezone.utc).isoformat(),
        "schema_version": "1.0-CI-DGI",
    }
