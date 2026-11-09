"""Stock à surveiller (tableau de bord) : règles pures.

Le restaurant ouvre du lundi au vendredi et le grand marché se fait le lundi matin. Un article
est à surveiller quand son stock ne tient pas jusqu'au prochain marché, au rythme des ventes
récentes (moyenne des derniers jours d'ouverture). Aucun seuil à régler.
"""

from datetime import date, timedelta
from decimal import Decimal
from enum import StrEnum

# Jours d'ouverture utilisés pour la vente moyenne, et période sans vente au-delà de laquelle
# un article à zéro est masqué (il réapparaît dès qu'il est réapprovisionné)
AVERAGE_OPEN_DAYS = 5
DORMANT_DAYS = 28


class StockWatchLevel(StrEnum):
    RUPTURE = "RUPTURE"  # plus rien en stock
    CRITIQUE = "CRITIQUE"  # ne tient pas une journée de vente
    BAS = "BAS"  # ne tient pas jusqu'au prochain marché
    OK = "OK"


LEVEL_ORDER = {
    StockWatchLevel.RUPTURE: 0,
    StockWatchLevel.CRITIQUE: 1,
    StockWatchLevel.BAS: 2,
    StockWatchLevel.OK: 3,
}


def next_market(today: date) -> date:
    """Prochain marché : le lundi suivant (le lundi même, le marché du jour est déjà fait)."""
    return today + timedelta(days=7 - today.weekday())


def open_days_to_market(today: date) -> int:
    """Jours d'ouverture à couvrir avant le prochain marché, aujourd'hui compris : 5 le lundi,
    1 le vendredi, 0 le week-end."""
    return max(0, 5 - today.weekday())


def coverage_days(quantity: Decimal, daily_sales: Decimal) -> Decimal | None:
    """Jours de vente que couvre le stock ; aucun (illimité) sans vente récente."""
    if daily_sales <= 0:
        return None
    return max(Decimal(0), quantity) / daily_sales


def level(quantity: Decimal, daily_sales: Decimal, days_needed: int) -> StockWatchLevel:
    if quantity <= 0:
        return StockWatchLevel.RUPTURE
    cover = coverage_days(quantity, daily_sales)
    if cover is None:
        return StockWatchLevel.OK
    if cover < 1:
        return StockWatchLevel.CRITIQUE
    if cover < days_needed:
        return StockWatchLevel.BAS
    return StockWatchLevel.OK


def is_hidden(quantity: Decimal, sold_recently: bool) -> bool:
    """Un article à zéro qu'on ne vend plus ne s'affiche pas (sinon « rupture » à vie)."""
    return quantity <= 0 and not sold_recently
