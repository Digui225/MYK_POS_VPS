"""Module déprécié conservé pour rétrocompatibilité.

Tous les modèles de rapport sont désormais consolidés dans `caisse.schemas.reports`.
"""

from caisse.schemas.reports import (
    CashierSalesResponse,
    ClosingStatusResponse,
    DashboardKpiResponse,
    HourlySalesItem,
    PaymentMethodSplit,
    TopProductReport,
)

__all__ = [
    "CashierSalesResponse",
    "ClosingStatusResponse",
    "DashboardKpiResponse",
    "HourlySalesItem",
    "PaymentMethodSplit",
    "TopProductReport",
]
