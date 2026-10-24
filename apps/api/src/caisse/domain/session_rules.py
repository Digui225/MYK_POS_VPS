import re
from datetime import date

from fastapi import status

from caisse.errors import CaisseException

VALID_DENOMINATIONS = [10000, 5000, 2000, 1000, 500, 200, 100, 50, 25, 10, 5]


def validate_business_date(business_date_str: str) -> date:
    """Valide le format YYYY-MM-DD de la journée comptable."""
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", business_date_str):
        raise CaisseException(
            code="INVALID_BUSINESS_DATE_FORMAT",
            title="Format de date comptable invalide",
            detail="La date comptable doit respecter le format YYYY-MM-DD.",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )
    try:
        return date.fromisoformat(business_date_str)
    except ValueError as err:
        raise CaisseException(
            code="INVALID_BUSINESS_DATE",
            title="Date comptable invalide",
            detail=str(err),
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        ) from err


def validate_opening_float(opening_float_xof: int) -> None:
    """Valide que le fonds de caisse est positif ou nul."""
    if opening_float_xof < 0:
        raise CaisseException(
            code="NEGATIVE_OPENING_FLOAT",
            title="Fonds de caisse négatif",
            detail="Le fonds de caisse initial ne peut pas être inférieur à 0 XOF.",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )


def calculate_counted_cash(breakdown: dict[str, int]) -> int:
    """Additionne le montant total des espèces comptées par coupures."""
    total_xof = 0
    for denom_str, count in breakdown.items():
        clean_denom_str = denom_str.removeprefix("coin_").removeprefix("bill_")
        try:
            denom = int(clean_denom_str)
        except ValueError as err:
            raise CaisseException(
                code="INVALID_DENOMINATION",
                title="Dénomination inconnue",
                detail=f"La dénomination '{denom_str}' n'est pas un nombre valide.",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            ) from err

        if count < 0:
            raise CaisseException(
                code="NEGATIVE_DENOMINATION_COUNT",
                title="Quantité de coupures négative",
                detail=f"Le nombre de coupures pour {denom} XOF ne peut pas être négatif.",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )
        total_xof += denom * count
    return total_xof


def calculate_variance(expected_cash_xof: int, counted_cash_xof: int) -> int:
    """Calcule l'écart de caisse (compté - théorique)."""
    return counted_cash_xof - expected_cash_xof
