from typing import Any

from fastapi import status

from caisse.domain.enums import OrderStatus
from caisse.domain.money import calculate_vat_split
from caisse.errors import CaisseException


def generate_order_number(business_date_str: str, sequence_number: int) -> str:
    """Génère le numéro lisible de commande : 2026-09-28-0042."""
    return f"{business_date_str}-{sequence_number:04d}"


def assert_order_editable(order_status: str) -> None:
    """Vérifie qu'une commande est dans un état modifiable (OPEN ou PARTIALLY_PAID)."""
    if order_status not in [OrderStatus.OPEN, OrderStatus.PARTIALLY_PAID]:
        raise CaisseException(
            code="ORDER_NOT_EDITABLE",
            title="Commande non modifiable",
            detail=f"Impossible de modifier une commande avec le statut '{order_status}'.",
            status_code=status.HTTP_409_CONFLICT,
            meta={"current_status": order_status},
        )


def calculate_line_total(unit_price_xof: int, quantity: int) -> int:
    """Calcule le total d'une ligne de commande en entier XOF."""
    if unit_price_xof < 0:
        raise CaisseException(
            code="INVALID_UNIT_PRICE",
            title="Prix unitaire négatif",
            detail="Le prix unitaire ne peut pas être inférieur à 0 XOF.",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )
    if quantity <= 0:
        raise CaisseException(
            code="INVALID_QUANTITY",
            title="Quantité invalide",
            detail="La quantité doit être supérieure ou égale à 1.",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )
    return unit_price_xof * quantity


def recalculate_order_totals(items: list[Any]) -> tuple[int, int, int]:
    """Recalcule les totaux (TTC, HT, TVA) d'une commande à partir de ses lignes actives."""
    total_ttc = 0
    total_ht = 0
    total_vat = 0

    for item in items:
        # Ne pas compter les lignes retirées
        if getattr(item, "removed_at", None) is not None:
            continue

        line_total = item.unit_price_xof * item.quantity
        ht, vat = calculate_vat_split(line_total, float(item.vat_rate))
        total_ttc += line_total
        total_ht += ht
        total_vat += vat

    return total_ttc, total_ht, total_vat
