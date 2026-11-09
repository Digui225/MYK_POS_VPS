from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from caisse.schemas.common import BaseSchema

# D9 : DRAFT (prévu) → VALIDATED (argent remis, stock inchangé) → COMPLETED (réceptionné)
# D10 : DRAFT → CANCELLED (annulé avant validation, motif obligatoire, jamais supprimé)
MarketPurchaseStatus = Literal["DRAFT", "VALIDATED", "COMPLETED", "CANCELLED"]
# D6 : état d'une sortie cuisine (contrôle sans effet sur le stock)
PreparationStatus = Literal["ESTIMATED", "VALIDATED", "ADJUSTED"]


class MarketPurchaseItemCreate(BaseModel):
    article_id: str | None = Field(None, description="ID de l'article de stock (si existant)")
    custom_article_name: str | None = Field(None, description="Nom si nouvel article créé à la volée par l'économe")
    unit: str | None = Field(None, description="Unité de mesure (kg, litre, pièce...)")
    category: str | None = Field(None, description="Famille/catégorie (PROTEINE, EPICERIE, etc.)")
    quantity: float = Field(..., gt=0, description="Quantité demandée au marché")
    unit_price_xof: int = Field(..., ge=0, description="Prix d'achat unitaire estimé/négocié")

    @field_validator("unit_price_xof", mode="before")
    @classmethod
    def round_unit_price(cls, v: object) -> object:
        if v is not None:
            try:
                return round(float(v))  # type: ignore[arg-type]
            except (ValueError, TypeError):
                pass
        return v


class MarketPurchaseItemOut(BaseSchema):
    id: str
    article_id: str
    article_name: str
    unit: str
    quantity: float
    unit_price_xof: int
    total_price_xof: int
    received_quantity: float | None = Field(
        None, description="Quantité réellement reçue ; null tant que le bon n'est pas réceptionné"
    )


class MarketPurchaseListCreate(BaseModel):
    business_date: date = Field(..., description="Date des achats")
    notes: str | None = Field(None, max_length=255)
    include_condiments_envelope: bool = Field(
        False, description="Inclure la dotation hebdomadaire de condiments"
    )
    items: list[MarketPurchaseItemCreate] = Field(..., min_length=1)


class MarketPurchaseListUpdate(BaseModel):
    notes: str | None = Field(None, max_length=255)
    include_condiments_envelope: bool | None = Field(
        None, description="Inclure la dotation hebdomadaire de condiments"
    )
    items: list[MarketPurchaseItemCreate] | None = Field(
        None, description="Liste mise à jour des articles"
    )


class MarketPurchaseListOut(BaseSchema):
    id: str
    business_date: date
    status: str
    created_by_user_id: str
    created_by_user_name: str
    validated_by_user_id: str | None
    validated_by_user_name: str | None
    total_budget_xof: int
    notes: str | None
    include_condiments_envelope: bool = False
    items: list[MarketPurchaseItemOut]
    created_at: datetime
    received_at: datetime | None = None
    stock_date: date | None = Field(
        None, description="Date d'entrée en stock des achats reçus (jour de la réception)"
    )
    received_by_user_name: str | None = None
    cancelled_at: datetime | None = None
    cancelled_by_user_name: str | None = None
    cancel_reason: str | None = None


class MarketPurchaseCancel(BaseModel):
    """Annulation d'un bon pas encore validé (D10)."""

    reason: str = Field(
        ..., min_length=3, max_length=200, description="Motif de l'annulation (obligatoire)"
    )


class MarketPurchaseReceiveLine(BaseModel):
    item_id: str = Field(..., description="Ligne du bon")
    received_quantity: float = Field(
        ..., ge=0, description="Quantité réellement reçue (0 : article non trouvé)"
    )


class MarketPurchaseReceive(BaseModel):
    """Réception d'un bon validé, ou correction d'un bon déjà réceptionné. Les quantités sont
    des valeurs cibles : renvoyer la même demande ne change rien."""

    lines: list[MarketPurchaseReceiveLine] = Field(
        default_factory=list,
        description=(
            "Quantités reçues. À la réception, une ligne absente vaut la quantité prévue ; "
            "à la correction, une ligne absente ne change pas"
        ),
    )
    reason: str | None = Field(
        None,
        max_length=200,
        description="Motif, obligatoire pour corriger un bon déjà réceptionné",
    )


class OpeningStockCorrection(BaseModel):
    """Correction du stock de départ d'un article à une date (valeur cible)."""

    article_id: str
    business_date: date = Field(..., description="Journée dont le stock de départ est corrigé")
    quantity: float = Field(..., ge=0, description="Stock de départ réel")
    reason: str = Field(..., min_length=3, max_length=200)


class OpeningStockCorrectionOut(BaseSchema):
    article_id: str
    article_name: str
    unit: str
    business_date: date
    previous_quantity: float
    quantity: float
    delta_quantity: float
    current_stock_quantity: float


class MarketBudgetStatusOut(BaseSchema):
    ratio: float
    percentage: int
    is_exceeded: bool
    level_text: str
    color_class: str
    total_budget_xof: int | None = None
    econome_limit_xof: int | None = None
    total_limit_xof: int | None = None
    other_envelope_xof: int | None = None
    real_disbursement_xof: int | None = None
    remaining_budget_xof: int | None = None
    remaining_econome_xof: int | None = None


class DailyPreparationCreate(BaseModel):
    business_date: date = Field(..., description="Date du jour de préparation")
    article_id: str = Field(..., description="ID de l'article protéine")
    prepared_quantity: float = Field(..., ge=0, description="Quantité sortie en cuisine (0 pour annuler/effacer)")
    yield_portions_per_unit: float = Field(
        ..., gt=0, description="Rendement en plats par unité de matière (ex: 4 plats/poulet)"
    )
    notes: str | None = Field(None, max_length=255)


class DailyPreparationOut(BaseSchema):
    id: str
    business_date: date
    article_id: str
    article_name: str
    unit: str
    prepared_quantity: float
    yield_portions_per_unit: float
    theoretical_dishes: int
    user_id: str
    user_name: str
    notes: str | None
    created_at: datetime
    status: PreparationStatus = "VALIDATED"
    estimated_quantity: float | None = Field(
        None, description="Dernière estimation calculée d'après les ventes de la journée"
    )


class DailyPreparationValidateDay(BaseModel):
    business_date: date = Field(..., description="Journée dont on valide les estimations")


class DailyPreparationValidateDayOut(BaseSchema):
    business_date: date
    validated_count: int
    preparations: list[DailyPreparationOut]


# Schémas pour la Matrice Hebdomadaire (Tableau Blanc du Patron)


class WeeklyDayData(BaseSchema):
    business_date: date
    day_name: str  # Lundi, Mardi, Mercredi...
    remaining_quantity: float = 0.0
    prepared_quantity: float
    suggested_quantity: float = 0.0
    yield_portions_per_unit: float
    theoretical_dishes: int
    sold_dishes: int
    normal_dishes_sold: int = 0
    foufou_dishes_sold: int = 0
    foutou_dishes_sold: int = 0
    foufou_price_xof: int = 0
    variance_dishes: int
    dish_price_xof: int
    expected_revenue_xof: int = 0
    actual_revenue_xof: int = 0
    revenue_variance_xof: int = 0
    financial_impact_xof: int
    notes: str | None = None
    # --- Grand livre du jour (D6) : identique au stock ---
    # remaining_quantity = disponible du jour (ouverture + achats du jour)
    opening_quantity: float = 0.0
    purchased_quantity: float = 0.0
    stock_sold_quantity: float = 0.0  # sorti du stock par les ventes, retours déduits
    loss_quantity: float = 0.0
    inventory_variance_quantity: float = 0.0  # écart d'inventaire signé
    correction_quantity: float = 0.0  # ajustements et rattrapages (migrations 024/025)
    closing_quantity: float = 0.0  # restant en fin de journée = stock à cette date
    # --- Contrôle de la sortie cuisine ---
    preparation_status: PreparationStatus | None = None
    estimated_quantity: float | None = None
    # sorti cuisine − besoin des plats encaissés (0 si aucune sortie saisie ce jour)
    preparation_gap_quantity: float = 0.0
    non_destocked_dishes: int = 0  # plats encaissés sans sortie de stock de cette protéine


class WeeklyProductRow(BaseSchema):
    article_id: str
    article_name: str
    unit: str
    opening_stock_qty: float = 0.0
    weekly_purchased_qty: float
    total_available_qty: float = 0.0
    purchase_unit_price_xof: int = 0
    weekly_purchased_cost_xof: int
    total_available_cost_xof: int = 0
    default_yield_portions: float
    weekly_potential_dishes: int
    dish_selling_price_xof: int = 0
    weekly_expected_revenue_xof: int = 0
    expected_margin_pct: float = 0.0
    days: list[WeeklyDayData]
    total_prepared_qty: float
    total_theoretical_dishes: int
    total_sold_dishes: int
    total_variance_dishes: int
    total_financial_impact_xof: int
    actual_revenue_xof: int = 0
    actual_gross_margin_xof: int = 0  # vente réelle − coût matière consommée (CMP)
    actual_gross_margin_pct: float = 0.0
    quantity_variance: float = 0.0  # somme des écarts des jours avec sortie saisie
    dishes_variance: int = 0  # plats vendus − plats possibles (> 0 : vendu plus que le stock)
    # --- Grand livre de la période (D6) ---
    total_stock_sold_qty: float = 0.0
    total_loss_qty: float = 0.0
    total_inventory_variance_qty: float = 0.0
    total_correction_qty: float = 0.0
    closing_stock_qty: float = 0.0  # restant de fin de période = stock à cette date
    current_stock_qty: float = 0.0  # stock actuel de l'article
    total_non_destocked_dishes: int = 0


class WeeklyMatrixReportOut(BaseSchema):
    date_from: date
    date_to: date
    daily_revenues: dict[str, int]  # ex: {"2026-10-19": 248500}
    total_weekly_revenue_xof: int
    total_weekly_purchases_xof: int
    total_variance_impact_xof: int
    gross_margin_estimate_xof: int
    rows: list[WeeklyProductRow]


# Comparatif & Écarts des 9 Protéines Marché vs Ventes Hebdomadaires


class ProteinComparisonRow(BaseSchema):
    article_id: str
    article_name: str
    unit: str
    requested_quantity: float
    unit_price_xof: int
    line_total_xof: int
    current_stock_quantity: float
    weekly_purchased_quantity: float
    weekly_prepared_quantity: float
    weekly_sold_dishes: int
    estimated_remaining_quantity: float
    recommended_quantity: float
    recommended_total_xof: int
    potential_savings_xof: int
    status_alert: str  # EXHAUSTED, PARTIAL, SURPLUS


class MarketProteinAnalysisOut(BaseSchema):
    purchase_id: str
    business_date: date
    week_start: date
    week_end: date
    proteins: list[ProteinComparisonRow]
    total_requested_proteins_cost_xof: int
    total_recommended_proteins_cost_xof: int
    total_potential_savings_xof: int

