"""Règles de stock pures (01-BACKEND §5.5) : coût moyen pondéré, valorisation, portions."""

from collections.abc import Iterable
from decimal import ROUND_FLOOR, ROUND_HALF_UP, Decimal

QTY = Decimal("0.001")
COST = Decimal("0.01")


def quantize_qty(value: Decimal) -> Decimal:
    return value.quantize(QTY, rounding=ROUND_HALF_UP)


def quantize_cost(value: Decimal) -> Decimal:
    return value.quantize(COST, rounding=ROUND_HALF_UP)


def weighted_average_cost(
    stock_qty: Decimal, stock_cost: Decimal, in_qty: Decimal, in_unit_cost: Decimal
) -> Decimal:
    """Coût moyen pondéré après une entrée. Un stock nul ou négatif n'a plus de valeur
    fiable : le prix de l'entrée devient le coût de référence."""
    if in_qty <= 0:
        return stock_cost
    if stock_qty <= 0:
        return quantize_cost(in_unit_cost)
    total = stock_qty * stock_cost + in_qty * in_unit_cost
    return quantize_cost(total / (stock_qty + in_qty))


def value_xof(quantity: Decimal, unit_cost: Decimal) -> int:
    """Valeur en francs CFA entiers (arrondi commercial)."""
    return int((quantity * unit_cost).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def portions_available(components: Iterable[tuple[Decimal, Decimal]]) -> Decimal | None:
    """Portions vendables d'un plat : minimum, sur ses composants (quantité par portion,
    stock de l'article), de stock ÷ quantité, arrondi à l'entier inférieur, jamais négatif.
    `None` si le plat n'a pas de fiche technique."""
    best: Decimal | None = None
    for per_portion, in_stock in components:
        portions = max(Decimal(0), (in_stock / per_portion).to_integral_value(ROUND_FLOOR))
        best = portions if best is None else min(best, portions)
    return best


def is_below_threshold(quantity: Decimal, threshold: Decimal | None) -> bool:
    """Alerte : stock négatif, ou au plus égal au seuil quand il est défini."""
    return quantity < 0 or (threshold is not None and quantity <= threshold)


def is_stock_low(quantity: float, alert_threshold: float) -> bool:
    """Alias rétrocompatible : détermine si le stock est en alerte (seuil bas ou négatif)."""
    return quantity <= alert_threshold


def validate_movement_quantity(quantity: float, movement_type: str) -> None:
    """Rétrocompatibilité : validation basique."""
    if movement_type == "INVENTORY_COUNT" and quantity < 0:
        raise ValueError("Quantité négative")
    elif quantity <= 0 and movement_type != "INVENTORY_COUNT":
        raise ValueError("Quantité invalide")


def calculate_quantity_after(current_quantity: float, movement_type: str, quantity: float) -> float:
    """Rétrocompatibilité : calcul élémentaire."""
    if movement_type in ["PURCHASE_IN", "RETURN_IN", "ADJUSTMENT"]:
        return round(current_quantity + quantity, 3)
    elif movement_type in ["SALE_OUT", "LOSS_OUT"]:
        return round(current_quantity - quantity, 3)
    elif movement_type == "INVENTORY_COUNT":
        return round(quantity, 3)
    return current_quantity

