from datetime import date
from typing import Annotated, Optional
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import Admin, DbSession, Responsable, get_current_user
from caisse.models.user import User
from caisse.schemas.report import DashboardKpiResponse
from caisse.schemas.reports import DashboardOut, SalesReportOut, StockReportOut
from caisse.services import reporting_service, stock_service
from caisse.services.reporting_service import ReportingService

router = APIRouter(prefix="/reports", tags=["Tableau de Bord & Rapports"])

DateFrom = Annotated[
    date | None, Query(description="Première journée incluse ; défaut : la date de fin")
]
DateTo = Annotated[
    date | None, Query(description="Dernière journée incluse ; défaut : journée en cours")
]


def _period(db: Session, date_from: date | None, date_to: date | None) -> tuple[date, date]:
    end = date_to or stock_service.business_day(db)
    return date_from or end, end


@router.get("/dashboard", response_model=DashboardKpiResponse, summary="Tableau de bord direction (KPIs)")
def get_dashboard_kpis(
    date: Optional[str] = Query(None, description="Date d'exploitation (YYYY-MM-DD), défaut aujourd'hui"),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    service = ReportingService(db)
    return service.get_dashboard_kpis(business_date_str=date)


@router.get("/overview", response_model=DashboardOut, summary="Tableau de bord de gestion de la journée")
def get_dashboard_overview(
    _: Responsable,
    db: DbSession,
    business_date: Annotated[
        date | None, Query(description="Journée comptable ; défaut : journée en cours")
    ] = None,
) -> DashboardOut:
    """Synthèse d'exploitation complète : ventes, couverts, tables, encaissements,
    top produits, heures, caissiers, sessions, alertes de stock et FNE."""
    return reporting_service.dashboard(db, business_date or stock_service.business_day(db))


@router.get("/sales", response_model=SalesReportOut, summary="Tableau des ventes et marges")
def sales_report_endpoint(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> SalesReportOut:
    """Commandes soldées de la période : chiffre d'affaires, coût matière des fiches techniques,
    marges, détail par jour, produit, catégorie et moyen de paiement, écarts de caisse."""
    start, end = _period(db, date_from, date_to)
    return reporting_service.sales_report(db, start, end)


@router.get("/stock", response_model=StockReportOut, summary="Tableau du stock et valorisation")
def stock_report_endpoint(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> StockReportOut:
    """Rapport de stock complet : stock initial, entrées achats, ventes sorties matière,
    pertes déclarées, écarts d'inventaire, stock final, valorisation au CMP et alertes."""
    start, end = _period(db, date_from, date_to)
    return reporting_service.stock_report(db, start, end)
