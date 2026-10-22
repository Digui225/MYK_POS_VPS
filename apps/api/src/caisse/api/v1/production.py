from datetime import date
from typing import Annotated
from fastapi import APIRouter, Depends, Query, status

from caisse.deps import CurrentUser, DbSession, Responsable
from caisse.schemas.production import (
    MarketPurchaseListCreate,
    MarketPurchaseListOut,
    DailyPreparationCreate,
    DailyPreparationOut,
    WeeklyMatrixReportOut,
)
from caisse.services import production_service

router = APIRouter(prefix="/production", tags=["Achats Marché & Production Cuisine"])

DateFrom = Annotated[date | None, Query(description="Première journée de la période")]
DateTo = Annotated[date | None, Query(description="Dernière journée de la période")]


@router.post(
    "/market-purchases",
    response_model=MarketPurchaseListOut,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un bon d'achat marché (caissière / responsable)",
)
def create_market_purchase_endpoint(
    payload: MarketPurchaseListCreate,
    current_user: CurrentUser,
    db: DbSession,
) -> MarketPurchaseListOut:
    """Enregistre la liste des courses prévisionnelles avant d'aller au marché.
    Calcule le montant total en FCFA à décaisser."""
    return production_service.create_market_purchase(db, current_user, payload)


@router.get(
    "/market-purchases",
    response_model=list[MarketPurchaseListOut],
    summary="Lister les bons d'achat du marché",
)
def list_market_purchases_endpoint(
    current_user: CurrentUser,
    db: DbSession,
    date_from: DateFrom = None,
    date_to: DateTo = None,
) -> list[MarketPurchaseListOut]:
    return production_service.list_market_purchases(db, date_from, date_to)


@router.get(
    "/market-purchases/{purchase_id}",
    response_model=MarketPurchaseListOut,
    summary="Consulter le détail d'un bon d'achat marché",
)
def get_market_purchase_endpoint(
    purchase_id: str,
    current_user: CurrentUser,
    db: DbSession,
) -> MarketPurchaseListOut:
    return production_service.get_market_purchase(db, purchase_id)


@router.post(
    "/market-purchases/{purchase_id}/complete",
    response_model=MarketPurchaseListOut,
    summary="Valider un bon d'achat marché et mettre à jour le stock (Responsable)",
)
def complete_market_purchase_endpoint(
    purchase_id: str,
    responsible_user: Responsable,
    db: DbSession,
    deduct_from_cash_session: bool = Query(
        False, description="Déduire automatiquement le montant de la caisse ouverte"
    ),
) -> MarketPurchaseListOut:
    """Valide les achats après retour du marché : met à jour les quantités en stock
    et alimente automatiquement la colonne ACHATS REÇUS du suivi journalier."""
    return production_service.complete_market_purchase(
        db, purchase_id, responsible_user, deduct_from_cash_session=deduct_from_cash_session
    )


@router.post(
    "/daily-preparations",
    response_model=DailyPreparationOut,
    summary="Enregistrer la sortie cuisine du matin (préparation journalière)",
)
def record_daily_prep_endpoint(
    payload: DailyPreparationCreate,
    current_user: CurrentUser,
    db: DbSession,
) -> DailyPreparationOut:
    """Enregistre la quantité de viande/poisson sortie en cuisine pour la journée
    et calcule immédiatement le nombre de plats prévus."""
    return production_service.save_daily_preparation(db, current_user, payload)


@router.get(
    "/weekly-matrix",
    response_model=WeeklyMatrixReportOut,
    summary="Matrice hebdomadaire Achats & Ventes (Tableau Blanc Patron)",
)
def get_weekly_matrix_endpoint(
    responsible_user: Responsable,
    db: DbSession,
    date_from: Annotated[date, Query(description="Date début de semaine (ex: Lundi)")],
    date_to: Annotated[date, Query(description="Date fin de semaine (ex: Vendredi)")],
) -> WeeklyMatrixReportOut:
    """Retourne la matrice complète pour le patron et le responsable :
    Achats de la semaine | ventilation journalière Lundi-Vendredi (Sorti, Prévu, Vendu caisse, Écart, Valeur) | Totaux."""
    return production_service.get_weekly_matrix(db, date_from, date_to)

