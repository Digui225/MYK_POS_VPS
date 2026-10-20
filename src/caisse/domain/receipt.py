"""Rendu texte brut des tickets (80 mm), sans I/O : la mise en page est testable sans agent
ni base. `width` est le nombre de caractères par ligne (`printer_width`, défaut 48). Fonctions
pures : comme `domain/fne.py`, elles prennent de petites structures locales, pas les modèles
ORM ni les schémas Pydantic, pour rester découplées des couches I/O."""

import textwrap
from collections.abc import Sequence
from dataclasses import dataclass

from caisse.domain.money import format_xof

_PAYMENT_LABELS = {
    "CASH": "Espèces",
    "MOBILE_MONEY": "Mobile Money",
    "CARD": "Carte bancaire",
    "BANK_TRANSFER": "Virement",
    "CREDIT": "Paiement différé",
    "OTHER": "Autre",
}
# Mobile Money : le client reconnaît son opérateur, pas « Mobile Money »
_PROVIDER_LABELS = {
    "WAVE": "Wave",
    "ORANGE": "Orange Money",
    "MTN": "MTN MoMo",
    "MOOV": "Moov Money",
}


def payment_label(method: str, provider: str | None = None) -> str:
    if method == "MOBILE_MONEY" and provider:
        return _PROVIDER_LABELS.get(provider.upper(), f"Mobile Money {provider}")
    return _PAYMENT_LABELS.get(method, method)


@dataclass(frozen=True, slots=True)
class ReceiptLine:
    name: str
    quantity: int
    line_total_xof: int
    note: str | None = None


@dataclass(frozen=True, slots=True)
class ReceiptPayment:
    method: str
    amount_xof: int
    change_xof: int = 0
    provider: str | None = None


@dataclass(frozen=True, slots=True)
class PaymentMethodAmount:
    method: str
    amount_xof: int


def _center(text: str, width: int) -> str:
    return text.center(width)


def _wrap(text: str, width: int, indent: str = "") -> list[str]:
    """Coupe aux espaces : sur 58 mm (32 caractères), l'imprimante couperait au milieu d'un mot."""
    return textwrap.wrap(text, width, subsequent_indent=indent) or [""]


def _centered(text: str, width: int) -> list[str]:
    return [_center(line, width) for line in _wrap(text, width)]


def _rule(width: int, char: str = "-") -> str:
    return char * width


def _two_cols(left: str, right: str, width: int) -> str:
    pad = width - len(left) - len(right)
    return left + (" " * max(pad, 1)) + right


def render_receipt(
    *,
    order_number: str,
    table_label: str | None,
    counter_number: int | None,
    items: Sequence[ReceiptLine],
    payments: Sequence[ReceiptPayment],
    total_ttc_xof: int,
    header_name: str,
    header_address: str | None,
    header_phone: str | None,
    footer: str,
    width: int = 48,
    header_ncc: str | None = None,
    header_rccm: str | None = None,
) -> str:
    lines: list[str] = _centered(header_name, width)
    if header_address:
        lines += _centered(header_address, width)
    if header_phone:
        lines += _centered(header_phone, width)
    legal_parts = [
        part
        for part in (header_ncc and f"NCC {header_ncc}", header_rccm and f"RCCM {header_rccm}")
        if part
    ]
    legal = " - ".join(legal_parts)
    if len(legal) <= width:
        lines += [_center(legal, width)] if legal else []
    else:  # 58 mm : un identifiant par ligne plutôt qu'un RCCM coupé
        lines += [_center(part, width) for part in legal_parts]
    lines.append(_rule(width))
    lines.append(f"N° {order_number}")
    if table_label:
        lines.append(f"Table {table_label}")
    elif counter_number is not None:
        lines.append(f"Comptoir n° {counter_number}")
    lines.append(_rule(width))
    for item in items:
        lines += _wrap(f"{item.quantity} x {item.name}", width, indent="    ")
        lines.append(_two_cols("", f"{format_xof(item.line_total_xof)} XOF", width))
        if item.note:
            lines += _wrap(f"  ({item.note})", width, indent="   ")
    lines.append(_rule(width))
    lines.append(_two_cols("TOTAL", f"{format_xof(total_ttc_xof)} XOF", width))
    for payment in payments:
        label = payment_label(payment.method, payment.provider)
        lines.append(_two_cols(label, f"{format_xof(payment.amount_xof)} XOF", width))
        if payment.change_xof:
            lines.append(_two_cols("Rendu", f"{format_xof(payment.change_xof)} XOF", width))
    lines.append(_rule(width))
    if footer:
        lines += _centered(footer, width)
    return "\n".join(lines)


def render_z_report(
    *,
    z_number: int,
    business_date: str,
    opening_float_xof: int,
    gross_ttc_xof: int,
    by_payment_method: Sequence[PaymentMethodAmount],
    expected_cash_xof: int,
    counted_cash_xof: int,
    variance_xof: int,
    cancelled_orders: int,
    removed_items: int,
    header_name: str,
    footer: str,
    width: int = 48,
) -> str:
    lines: list[str] = [
        *_centered(header_name, width),
        _center(f"RAPPORT Z n° {z_number}", width),
        _center(business_date, width),
        _rule(width),
        _two_cols("Fonds de caisse", f"{format_xof(opening_float_xof)} XOF", width),
        _two_cols("CA TTC", f"{format_xof(gross_ttc_xof)} XOF", width),
        _rule(width),
    ]
    for method_total in by_payment_method:
        label = _PAYMENT_LABELS.get(method_total.method, method_total.method)
        lines.append(_two_cols(label, f"{format_xof(method_total.amount_xof)} XOF", width))
    lines += [
        _rule(width),
        _two_cols("Attendu tiroir", f"{format_xof(expected_cash_xof)} XOF", width),
        _two_cols("Compté tiroir", f"{format_xof(counted_cash_xof)} XOF", width),
        _two_cols("Écart", f"{format_xof(variance_xof)} XOF", width),
        _rule(width),
        _two_cols("Annulations / retraits", f"{cancelled_orders} / {removed_items}", width),
    ]
    if footer:
        lines += _centered(footer, width)
    return "\n".join(lines)


def render_test_ticket(*, printed_at: str, width: int = 48) -> str:
    """Ticket de test (`POST /printing/test`) : largeur, accents, chaîne API → agent."""
    return "\n".join(
        [
            _center("TICKET DE TEST", width),
            _rule(width),
            f"Largeur    : {width} caractères",
            f"Date       : {printed_at}",
            "Accents    : é è à ç ô û",  # CP858 : pas de tiret long
            _rule(width),
            *_centered("Si ce ticket est lisible, l'agent fonctionne.", width),
        ]
    )
