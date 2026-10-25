import csv
import io
from datetime import date
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from caisse.core.database import get_db
from caisse.core.deps import DbSession, Responsable, get_current_user
from caisse.models.user import User
from caisse.schemas.reports import (
    DashboardKpiResponse,
    DashboardOut,
    ProteinYieldReportOut,
    SalesReportOut,
    StockReportOut,
)
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
) -> DashboardKpiResponse:
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


@router.get("/sales/export", summary="Export CSV du tableau des ventes et marges")
def export_sales_csv(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> Response:
    """Génère et télécharge un fichier CSV formaté pour Excel avec séparateur point-virgule (BOM UTF-8)
    reprenant le suivi journalier des ventes, achats, marges, dépenses et versements banque."""
    start, end = _period(db, date_from, date_to)
    report = reporting_service.sales_report(db, start, end)

    output = io.StringIO()
    writer = csv.writer(output, delimiter=";")
    writer.writerow([
        "Jour",
        "Date",
        "Commandes",
        "Achats Reçus (XOF)",
        "Achats Utilisés (Matières) (XOF)",
        "Ventes (CA) (XOF)",
        "Marge Brute (XOF)",
        "Taux Marge (%)",
        "Dépenses Caisse (XOF)",
        "Résultat Net (XOF)",
        "Total Versé (Espèces) (XOF)",
        "Écart Caisse (XOF)",
        "Versement Banque (XOF)",
    ])

    for day in report.by_day:
        day_date_str = day.business_date.isoformat() if hasattr(day.business_date, "isoformat") else str(day.business_date)
        day_num = day.business_date.day if hasattr(day.business_date, "day") else (int(day_date_str.split("-")[2]) if "-" in day_date_str else 1)
        used_amount = (day.recipe_cost_xof or 0) + (day.inventory_consumption_xof or 0)
        writer.writerow([
            f"Jour {day_num}",
            day_date_str,
            day.orders_count or 0,
            day.purchases_xof or 0,
            used_amount,
            day.revenue_xof or 0,
            day.gross_margin_xof or 0,
            f"{day.gross_margin_rate or 0}%",
            day.expenses_xof or 0,
            day.net_result_xof or 0,
            day.counted_cash_xof or 0,
            day.cash_variance_xof or 0,
            day.bank_deposit_xof or 0,
        ])

    totals = report.totals
    total_purchases = sum(d.purchases_xof or 0 for d in report.by_day)
    total_used = (totals.recipe_cost_xof or 0) + (totals.inventory_consumption_xof or 0)
    total_margin_rate = (
        round((totals.gross_margin_xof / totals.revenue_xof) * 100, 1)
        if totals.revenue_xof and totals.revenue_xof > 0
        else 0
    )
    total_counted_cash = sum(d.counted_cash_xof or 0 for d in report.by_day)
    total_cash_variance = sum(d.cash_variance_xof or 0 for d in report.by_day)

    writer.writerow([
        "TOTAL MENSUEL",
        f"{start} au {end}",
        totals.orders_count or 0,
        total_purchases,
        total_used,
        totals.revenue_xof or 0,
        totals.gross_margin_xof or 0,
        f"{total_margin_rate}%",
        totals.expenses_xof or 0,
        totals.net_result_xof or 0,
        total_counted_cash,
        total_cash_variance,
        totals.bank_deposit_xof or 0,
    ])

    csv_content = "\ufeff" + output.getvalue()
    return Response(
        content=csv_content.encode("utf-8"),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="suivi_ventes_{start}_{end}.csv"'
        },
    )


@router.get(
    "/protein-yields",
    response_model=ProteinYieldReportOut,
    summary="Contrôle des rendements de viandes et protéines",
)
def protein_yields_endpoint(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> ProteinYieldReportOut:
    """Contrôle des rendements des protéines : compare la matière première sortie
    avec les portions théoriques attendues d'après les fiches techniques, les plats
    réellement vendus en caisse et les pertes déclarées pour détecter les anomalies."""
    start, end = _period(db, date_from, date_to)
    return reporting_service.protein_yield_report(db, start, end)


@router.get("/protein-yields/export", summary="Export CSV du contrôle des rendements viandes et poissons")
def export_protein_yields_csv(
    _: Responsable,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> Response:
    """Génère et télécharge un fichier CSV formaté pour Excel avec séparateur point-virgule
    détaillant le rendement des viandes et poissons (sorties stock vs fiches vs plats vendus)."""
    start, end = _period(db, date_from, date_to)
    report = reporting_service.protein_yield_report(db, start, end)

    output = io.StringIO()
    writer = csv.writer(output, delimiter=";")
    writer.writerow([
        "Protéine",
        "Unité",
        "Stock Sorti",
        "Portions Théoriques",
        "Portions Vendues",
        "Pertes Déclarées",
        "Écart Portions",
        "Rendement (%)",
        "Impact Financier (XOF)",
        "Statut",
    ])

    for item in report.items:
        yield_rate = (
            round((item.sold_dishes / item.theoretical_dishes) * 100, 1)
            if item.theoretical_dishes > 0
            else 100.0
        )
        writer.writerow([
            item.article_name,
            item.unit,
            item.consumed_quantity,
            item.theoretical_dishes,
            item.sold_dishes,
            item.loss_dishes,
            item.variance_dishes,
            f"{yield_rate}%",
            item.financial_impact_xof,
            item.status,
        ])

    totals = report.totals
    total_yield = (
        round((totals.total_sold_dishes / totals.total_theoretical_dishes) * 100, 1)
        if totals.total_theoretical_dishes > 0
        else 100.0
    )
    writer.writerow([
        "TOTAL",
        "—",
        "—",
        totals.total_theoretical_dishes,
        totals.total_sold_dishes,
        sum(item.loss_dishes for item in report.items),
        totals.total_variance_dishes,
        f"{total_yield}%",
        totals.total_financial_impact_xof,
        f"{totals.anomalies_count} anomalie(s)" if totals.anomalies_count > 0 else "CONFORME",
    ])

    csv_content = "\ufeff" + output.getvalue()
    return Response(
        content=csv_content.encode("utf-8"),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="rendement_proteines_{start}_{end}.csv"'
        },
    )

