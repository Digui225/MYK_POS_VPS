from datetime import date
from typing import Annotated

from fastapi import APIRouter, Query, status

from caisse.core.deps import Ctx, CurrentUser, DbSession, EconomeOnly, Responsable
from caisse.schemas.production import (
    DailyPreparationCreate,
    DailyPreparationOut,
    DailyPreparationValidateDay,
    DailyPreparationValidateDayOut,
    MarketProteinAnalysisOut,
    MarketPurchaseCancel,
    MarketPurchaseListCreate,
    MarketPurchaseListOut,
    MarketPurchaseListUpdate,
    MarketPurchaseReceive,
    OpeningStockCorrection,
    OpeningStockCorrectionOut,
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


@router.put(
    "/market-purchases/{purchase_id}",
    response_model=MarketPurchaseListOut,
    summary="Mettre à jour un bon d'achat marché en attente (Patron / Responsable)",
)
def update_market_purchase_endpoint(
    purchase_id: str,
    payload: MarketPurchaseListUpdate,
    current_user: CurrentUser,
    db: DbSession,
) -> MarketPurchaseListOut:
    """Met à jour les articles et quantités d'un bon en attente (DRAFT).
    Permet au Patron d'ajuster les quantités après analyse des écarts."""
    return production_service.update_market_purchase(db, purchase_id, current_user, payload)


@router.get(
    "/market-purchases/{purchase_id}/protein-analysis",
    response_model=MarketProteinAnalysisOut,
    summary="Analyse comparative des 9 protéines du bon vs ventes de la semaine",
)
def get_market_purchase_protein_analysis_endpoint(
    purchase_id: str,
    current_user: CurrentUser,
    db: DbSession,
) -> MarketProteinAnalysisOut:
    """Compare les quantités demandées sur ce bon pour les 9 protéines avec
    les ventes, préparations cuisine et restes en stock sur la semaine."""
    return production_service.get_market_purchase_protein_analysis(db, purchase_id)



@router.post(
    "/market-purchases/{purchase_id}/complete",
    response_model=MarketPurchaseListOut,
    summary="Valider un bon d'achat marché : argent remis, stock inchangé (Responsable)",
)
def complete_market_purchase_endpoint(
    purchase_id: str,
    responsible_user: Responsable,
    db: DbSession,
    deduct_from_cash_session: bool = Query(
        False, description="Déduire automatiquement le montant de la caisse ouverte"
    ),
) -> MarketPurchaseListOut:
    """`DRAFT` → `VALIDATED` (D9) : l'argent est remis à l'économe, le stock ne bouge pas.
    Les achats entrent en stock à la réception (`/receive`), avec les quantités réellement
    reçues. Rejouer la validation d'un bon déjà validé ne fait rien."""
    return production_service.complete_market_purchase(
        db, purchase_id, responsible_user, deduct_from_cash_session=deduct_from_cash_session
    )


@router.post(
    "/market-purchases/{purchase_id}/cancel",
    response_model=MarketPurchaseListOut,
    summary="Annuler un bon d'achat marché pas encore validé (Responsable, Admin, Économe)",
)
def cancel_market_purchase_endpoint(
    purchase_id: str,
    payload: MarketPurchaseCancel,
    user: EconomeOnly,
    db: DbSession,
    ctx: Ctx,
) -> MarketPurchaseListOut:
    """`DRAFT` → `CANCELLED` (D10), motif obligatoire. Le bon n'est jamais supprimé : il reste
    dans l'historique. L'économe n'annule que les bons qu'il a préparés. Un bon validé ou
    réceptionné ne peut pas être annulé (409 `PURCHASE_NOT_CANCELLABLE`). Rejouer l'annulation
    d'un bon déjà annulé ne change rien."""
    return production_service.cancel_market_purchase(
        db, purchase_id, payload, user=user, ctx=ctx
    )


@router.post(
    "/market-purchases/{purchase_id}/receive",
    response_model=MarketPurchaseListOut,
    summary="Réceptionner un bon validé, ou corriger les quantités reçues (Responsable)",
)
def receive_market_purchase_endpoint(
    purchase_id: str,
    payload: MarketPurchaseReceive,
    responsible_user: Responsable,
    db: DbSession,
    ctx: Ctx,
) -> MarketPurchaseListOut:
    """`VALIDATED` → `COMPLETED` : les quantités réellement reçues entrent en stock (une ligne
    absente vaut la quantité prévue, 0 si l'article n'a pas été trouvé), au prix du bon et à la
    date du bon ; le kit condiments éventuel entre aussi en stock.

    Sur un bon `COMPLETED`, corrige les quantités reçues (motif obligatoire) : l'écart est une
    entrée ou un retrait d'achat signé, daté du bon et tracé ; aucun mouvement n'est modifié.
    Les quantités sont des valeurs cibles : rejouer la même demande ne change rien."""
    return production_service.receive_market_purchase(
        db, purchase_id, payload, user=responsible_user, ctx=ctx
    )


@router.post(
    "/opening-stock-corrections",
    response_model=OpeningStockCorrectionOut,
    summary="Corriger le stock de départ d'un article à une journée (Responsable)",
)
def correct_opening_stock_endpoint(
    payload: OpeningStockCorrection,
    responsible_user: Responsable,
    db: DbSession,
    ctx: Ctx,
) -> OpeningStockCorrectionOut:
    """Le stock de départ de l'article à `business_date` devient `quantity` : l'écart est un
    mouvement de stock de départ (`OPENING`) daté de cette journée et tracé. Les journées
    suivantes, stock actuel compris, sont décalées du même écart. Valeur cible : rejouer la
    même demande ne change rien."""
    return production_service.correct_opening_stock(
        db, payload, user=responsible_user, ctx=ctx
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


@router.post(
    "/daily-preparations/validate-day",
    response_model=DailyPreparationValidateDayOut,
    summary="Valider d'un coup les sorties cuisine estimées d'une journée",
)
def validate_day_preparations_endpoint(
    payload: DailyPreparationValidateDay,
    current_user: CurrentUser,
    db: DbSession,
) -> DailyPreparationValidateDayOut:
    """La cuisine confirme les sorties estimées à la clôture de caisse (état ESTIMATED →
    VALIDATED). Les sorties déjà validées ou ajustées ne changent pas. Sans effet sur le stock."""
    return production_service.validate_day_preparations(db, current_user, payload.business_date)


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

