from decimal import ROUND_HALF_UP, Decimal
from typing import Any


def to_xof(value: Decimal | int | float) -> int:
    """Arrondi au franc XOF le plus proche (demi-point supérieur).

    Sert pour tous les totaux, montants encaissés et valorisations globales en XOF.
    """
    d = Decimal(str(value)) if not isinstance(value, Decimal) else value
    return int(d.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def to_unit_rate(value: Decimal | int | float) -> float:
    """Arrondi du taux ou prix unitaire de valorisation à 2 décimales max (demi-point supérieur).

    Exception documentée (D3) : les coûts moyens pondérés (CMP) et prix unitaires d'achat
    tolèrent 2 décimales pour les fiches techniques portant sur des sous-unités (grammes, cl).
    """
    d = Decimal(str(value)) if not isinstance(value, Decimal) else value
    return float(d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def calculate_vat_split(total_ttc_xof: int, vat_rate: Decimal | float | int | Any = Decimal("18.0")) -> tuple[int, int]:
    """Calcule la ventilation HT et TVA depuis un montant TTC en entier XOF.

    Règle métier ADR-04 :
    - Le TTC fait foi (entier XOF).
    - HT = arrondi commercial à l'entier le plus proche (demi-point supérieur).
    - TVA = TTC - HT
    """
    if total_ttc_xof <= 0:
        return 0, 0
    rate = Decimal(str(vat_rate)) if not isinstance(vat_rate, Decimal) else vat_rate
    if rate <= 0:
        return total_ttc_xof, 0
    factor = Decimal(1) + (rate / Decimal(100))
    ht_xof = int((Decimal(total_ttc_xof) / factor).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    vat_xof = total_ttc_xof - ht_xof
    return ht_xof, vat_xof


def calculate_change(tendered_xof: int | None, amount_due_xof: int) -> int:
    """Calcule le rendu monnaie en XOF."""
    if tendered_xof is None or tendered_xof <= amount_due_xof:
        return 0
    return tendered_xof - amount_due_xof
