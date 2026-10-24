import math
from typing import Any


def calculate_vat_split(total_ttc_xof: int, vat_rate: float | int | Any = 18.0) -> tuple[int, int]:
    """Calcule la ventilation HT et TVA depuis un montant TTC en entier XOF.

    Règle métier ADR-04 :
    - Le TTC fait foi (entier XOF).
    - HT = arrondi commercial à l'entier le plus proche (demi-point supérieur) :
      ht = floor(ttc / (1 + taux/100) + 0.5)
    - TVA = TTC - HT
    """
    if total_ttc_xof <= 0:
        return 0, 0
    rate_val = float(vat_rate)
    if rate_val <= 0:
        return total_ttc_xof, 0
    rate_factor = 1.0 + (rate_val / 100.0)
    ht_xof = int(math.floor((total_ttc_xof / rate_factor) + 0.5))
    vat_xof = total_ttc_xof - ht_xof
    return ht_xof, vat_xof


def calculate_change(tendered_xof: int | None, amount_due_xof: int) -> int:
    """Calcule le rendu monnaie en XOF."""
    if tendered_xof is None or tendered_xof <= amount_due_xof:
        return 0
    return tendered_xof - amount_due_xof
