"""Construction des requêtes vers l'API FNE de la DGI (procédure d'interfaçage, mai 2025).

Fonctions pures, zéro I/O. La caisse raisonne en TTC entier (ADR-04) ; la FNE attend un prix
unitaire **HT** par article et recalcule la TVA elle-même : le HT est donc déduit du TTC ici,
avec une précision réglable (`ht_decimals`) tant que la sonde n'a pas tranché (PLAN-FNE D2).
"""
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from enum import StrEnum
from typing import Any, Protocol

from caisse.domain.enums import PaymentMethod


class FneTemplate(StrEnum):
    B2C = "B2C"  # particulier
    B2B = "B2B"  # entreprise avec NCC
    B2G = "B2G"  # institution gouvernementale
    B2F = "B2F"  # client à l'international


class FneMappingError(ValueError):
    """Commande impossible à traduire en requête FNE (donnée manquante ou non mappée)."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


# Annexe 1 de la procédure. 0 % → TVAD (exonération légale), décision client du 01/10/2026.
# L'API accepte aussi TVAE (absent de la procédure, signification à confirmer avec la DGI).
DEFAULT_VAT_CODES: Mapping[Decimal, str] = {
    Decimal("18"): "TVA",
    Decimal("9"): "TVAB",
    Decimal("0"): "TVAD",
}

# OTHER volontairement absent : à paramétrer explicitement (`fne.payment_methods`).
DEFAULT_PAYMENT_METHODS: Mapping[PaymentMethod, str] = {
    PaymentMethod.CASH: "cash",
    PaymentMethod.CARD: "card",
    PaymentMethod.MOBILE_MONEY: "mobile-money",
    PaymentMethod.BANK_TRANSFER: "transfer",
    PaymentMethod.CREDIT: "deferred",
}


@dataclass(frozen=True, slots=True)
class FneLine:
    description: str
    quantity: int
    unit_price_ttc_xof: int
    vat_rate: Decimal  # en %, ex. Decimal("18.00")
    reference: str | None = None
    measurement_unit: str | None = None


@dataclass(frozen=True, slots=True)
class FneClient:
    company_name: str
    phone: str
    email: str
    ncc: str | None = None
    seller_name: str | None = None


@dataclass(frozen=True, slots=True)
class FneIssuer:
    """Doit correspondre exactement à la configuration de l'espace FNE (sinon 400)."""

    point_of_sale: str
    establishment: str
    commercial_message: str | None = None
    footer: str | None = None


def unit_price_ht(unit_price_ttc_xof: int, vat_rate: Decimal, decimals: int) -> Decimal:
    """1000 TTC à 18 % → 847.4576 (4 décimales) ou 847 (0 décimale)."""
    if decimals < 0:
        raise ValueError("decimals doit être positif")
    ht = Decimal(unit_price_ttc_xof) / (Decimal(1) + Decimal(vat_rate) / Decimal(100))
    return ht.quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)


def vat_code(vat_rate: Decimal, codes: Mapping[Decimal, str] = DEFAULT_VAT_CODES) -> str:
    rate = Decimal(vat_rate).normalize()
    for known, code in codes.items():
        if Decimal(known).normalize() == rate:
            return code
    raise FneMappingError("FNE_VAT_RATE_UNMAPPED", f"Taux de TVA sans code FNE : {vat_rate} %")


def payment_method_code(
    method: PaymentMethod, codes: Mapping[PaymentMethod, str] = DEFAULT_PAYMENT_METHODS
) -> str:
    try:
        return codes[method]
    except KeyError:
        raise FneMappingError(
            "FNE_PAYMENT_METHOD_UNMAPPED", f"Moyen de paiement sans code FNE : {method}"
        ) from None


def dominant_payment_method(payments: Sequence[tuple[PaymentMethod, int]]) -> PaymentMethod:
    """La FNE n'accepte qu'un moyen par facture : on retient celui du plus gros montant cumulé
    (à égalité, le premier encaissé)."""
    if not payments:
        raise FneMappingError("FNE_NO_PAYMENT", "Aucun paiement pour déterminer le moyen")
    totals: dict[PaymentMethod, int] = {}
    for method, amount in payments:
        totals[method] = totals.get(method, 0) + amount
    return max(totals, key=lambda m: totals[m])  # max garde le premier à égalité


def build_sale_request(
    *,
    lines: Sequence[FneLine],
    client: FneClient,
    template: FneTemplate,
    payment_method: str,
    issuer: FneIssuer,
    vat_codes: Mapping[Decimal, str] = DEFAULT_VAT_CODES,
    ht_decimals: int = 4,
) -> dict[str, Any]:
    """Corps de `POST /external/invoices/sign` (facture de vente). Les montants HT restent en
    `Decimal` : la sérialisation JSON est l'affaire de l'infrastructure."""
    if not lines:
        raise FneMappingError("FNE_EMPTY_INVOICE", "Facture sans article")
    if template is FneTemplate.B2B and not (client.ncc or "").strip():
        raise FneMappingError("FNE_NCC_REQUIRED", "NCC du client obligatoire en B2B")
    for field, value in (
        ("clientCompanyName", client.company_name),
        ("clientPhone", client.phone),
        ("clientEmail", client.email),
        ("pointOfSale", issuer.point_of_sale),
        ("establishment", issuer.establishment),
    ):
        if not value.strip():
            raise FneMappingError("FNE_FIELD_REQUIRED", f"Champ FNE obligatoire vide : {field}")

    items: list[dict[str, Any]] = []
    for line in lines:
        if line.quantity <= 0 or line.unit_price_ttc_xof < 0:
            raise FneMappingError("FNE_INVALID_LINE", f"Ligne invalide : {line.description}")
        item: dict[str, Any] = {
            "taxes": [vat_code(line.vat_rate, vat_codes)],  # l'API exige exactement un code
            "description": line.description,
            "quantity": line.quantity,
            "amount": unit_price_ht(line.unit_price_ttc_xof, line.vat_rate, ht_decimals),
        }
        if line.reference:
            item["reference"] = line.reference
        if line.measurement_unit:
            item["measurementUnit"] = line.measurement_unit
        items.append(item)

    body: dict[str, Any] = {
        "invoiceType": "sale",
        "paymentMethod": payment_method,
        "template": template.value,
        "isRne": False,
        "clientCompanyName": client.company_name,
        "clientPhone": client.phone,  # chaîne, malgré le « int » de la procédure
        "clientEmail": client.email,
        "pointOfSale": issuer.point_of_sale,
        "establishment": issuer.establishment,
        "foreignCurrency": "",
        "foreignCurrencyRate": 0,
        "items": items,
    }
    if client.ncc:
        body["clientNcc"] = client.ncc
    if client.seller_name:
        body["clientSellerName"] = client.seller_name
    if issuer.commercial_message:
        body["commercialMessage"] = issuer.commercial_message
    if issuer.footer:
        body["footer"] = issuer.footer
    return body


def json_safe(value: Any) -> Any:
    """Copie sérialisable en JSON (colonne JSONB) : `Decimal` entier → int, sinon float."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list | tuple):
        return [json_safe(item) for item in value]
    return value


def build_refund_request(items: Sequence[tuple[str, int]]) -> dict[str, Any]:
    """Corps de `POST /external/invoices/{id}/refund` : (id d'article FNE, quantité rendue)."""
    if not items:
        raise FneMappingError("FNE_EMPTY_REFUND", "Avoir sans article")
    for item_id, quantity in items:
        if not item_id or quantity <= 0:
            raise FneMappingError("FNE_INVALID_LINE", f"Ligne d'avoir invalide : {item_id}")
    return {"items": [{"id": item_id, "quantity": quantity} for item_id, quantity in items]}


@dataclass(frozen=True, slots=True)
class FneItemRef:
    """Article tel que certifié par la FNE : son `id` est requis pour un avoir."""

    id: str
    description: str
    quantity: int
    reference: str | None


@dataclass(frozen=True, slots=True)
class FneResult:
    external_number: str  # `reference` FNE, ex. 1304777N26000000023
    qr_payload: str  # `token` : URL de vérification à imprimer en QR
    invoice_id: str | None  # `invoice.id`, requis pour un avoir (absent des réponses d'avoir)
    items: tuple[FneItemRef, ...]
    amount_ttc: int | None
    vat_amount: int | None
    balance_sticker: int | None
    sticker_warning: bool
    raw: dict[str, Any]


class FneError(Exception):
    """Échec d'un appel FNE. Le type dit si un renvoi automatique est sans danger."""

    def __init__(self, message: str, *, status: int | None = None, body: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


class FneRejectedError(FneError):
    """4xx (hors 401) : données refusées, correction nécessaire. Rien n'a été certifié."""


class FneAuthError(FneError):
    """401 : clé API invalide. Rien n'a été certifié ; renvoi possible une fois la clé corrigée."""


class FneUnavailableError(FneError):
    """La requête n'a pas été traitée (connexion impossible, 502/503) : renvoi sans danger."""


class FneUncertainError(FneError):
    """La requête a pu être traitée (délai dépassé après envoi, 500, 504, réponse illisible) :
    **jamais** de renvoi automatique, l'API n'étant pas idempotente (PLAN-FNE D5)."""


class FneProvider(Protocol):
    def sign(self, payload: dict[str, Any], *, timeout: float) -> FneResult: ...

    def refund(self, invoice_id: str, payload: dict[str, Any], *, timeout: float) -> FneResult: ...
