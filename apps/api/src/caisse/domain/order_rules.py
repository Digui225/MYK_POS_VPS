from typing import Any

from fastapi import status

from caisse.core.errors import CaisseException
from caisse.domain.enums import OrderStatus, UserRole
from caisse.domain.money import calculate_vat_split


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


MANAGER_ROLES = frozenset({UserRole.RESPONSABLE, UserRole.ADMIN})


def assert_order_cancellable(
    order_status: str, *, has_payment: bool, active_total_xof: int, role: str
) -> None:
    """Annulation d'une commande à la caisse.

    - jamais après un paiement, même partiel (rien ne s'efface après encaissement) ;
    - la caissière annule seule une commande à 0 F (vide ou dont tous les plats ont été retirés,
      chaque retrait ayant déjà son motif) ;
    - s'il reste des articles, il faut un responsable ou un admin (un plat envoyé a été préparé).
    """
    assert_order_editable(order_status)  # soldée ou annulée : ORDER_NOT_EDITABLE, comme avant
    if has_payment or order_status == OrderStatus.PARTIALLY_PAID:
        raise CaisseException(
            code="ORDER_HAS_PAYMENTS",
            title="Commande déjà encaissée",
            detail="Une commande qui a reçu un paiement ne s'annule pas : passer par un avoir.",
            status_code=status.HTTP_409_CONFLICT,
        )
    if active_total_xof > 0 and role not in MANAGER_ROLES:
        raise CaisseException(
            code="ORDER_CANCEL_REQUIRES_MANAGER",
            title="Accord d'un responsable nécessaire",
            detail=(
                "La commande contient encore des articles : retirez-les un à un avec leur motif, "
                "ou demandez à un responsable de l'annuler."
            ),
            status_code=status.HTTP_403_FORBIDDEN,
        )


def calculate_line_total(unit_price_xof: int, quantity: int) -> int:
    """Calcule le total d'une ligne de commande en entier XOF."""
    if unit_price_xof < 0:
        raise CaisseException(
            code="INVALID_UNIT_PRICE",
            title="Prix unitaire négatif",
            detail="Le prix unitaire ne peut pas être inférieur à 0 XOF.",
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    if quantity <= 0:
        raise CaisseException(
            code="INVALID_QUANTITY",
            title="Quantité invalide",
            detail="La quantité doit être supérieure ou égale à 1.",
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
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
        ht, vat = calculate_vat_split(line_total, item.vat_rate)
        total_ttc += line_total
        total_ht += ht
        total_vat += vat

    return total_ttc, total_ht, total_vat
