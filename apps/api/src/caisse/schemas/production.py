from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field

from caisse.schemas.common import BaseSchema

MarketPurchaseStatus = Literal["DRAFT", "COMPLETED", "CANCELLED"]


class MarketPurchaseItemCreate(BaseModel):
    article_id: str | None = Field(None, description="ID de l'article de stock (si existant)")
    custom_article_name: str | None = Field(None, description="Nom si nouvel article créé à la volée par l'économe")
    unit: str | None = Field(None, description="Unité de mesure (kg, litre, pièce...)")
    category: str | None = Field(None, description="Famille/catégorie (PROTEINE, EPICERIE, etc.)")
    quantity: float = Field(..., gt=0, description="Quantité demandée au marché")
    unit_price_xof: int = Field(..., ge=0, description="Prix d'achat unitaire estimé/négocié")


class MarketPurchaseItemOut(BaseSchema):
    id: str
    article_id: str
    article_name: str
    unit: str
    quantity: float
    unit_price_xof: int
    total_price_xof: int


class MarketPurchaseListCreate(BaseModel):
    business_date: date = Field(..., description="Date des achats")
    notes: str | None = Field(None, max_length=255)
    items: list[MarketPurchaseItemCreate] = Field(..., min_length=1)


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
    items: list[MarketPurchaseItemOut]
    created_at: datetime


class MarketBudgetStatusOut(BaseSchema):
    ratio: float
    percentage: int
    is_exceeded: bool
    level_text: str
    color_class: str
    total_budget_xof: int | None = None
    econome_limit_xof: int | None = None
    total_limit_xof: int | None = None
    remaining_budget_xof: int | None = None
    remaining_econome_xof: int | None = None


class DailyPreparationCreate(BaseModel):
    business_date: date = Field(..., description="Date du jour de préparation")
    article_id: str = Field(..., description="ID de l'article protéine")
    prepared_quantity: float = Field(..., gt=0, description="Quantité sortie en cuisine")
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
    foufou_price_xof: int = 0
    variance_dishes: int
    dish_price_xof: int
    expected_revenue_xof: int = 0
    actual_revenue_xof: int = 0
    revenue_variance_xof: int = 0
    financial_impact_xof: int


class WeeklyProductRow(BaseSchema):
    article_id: str
    article_name: str
    unit: str
    weekly_purchased_qty: float
    purchase_unit_price_xof: int = 0
    weekly_purchased_cost_xof: int
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
    actual_gross_margin_xof: int = 0
    actual_gross_margin_pct: float = 0.0
    quantity_variance: float = 0.0
    dishes_variance: int = 0


class WeeklyMatrixReportOut(BaseSchema):
    date_from: date
    date_to: date
    daily_revenues: dict[str, int]  # ex: {"2026-10-19": 248500}
    total_weekly_revenue_xof: int
    total_weekly_purchases_xof: int
    total_variance_impact_xof: int
    gross_margin_estimate_xof: int
    rows: list[WeeklyProductRow]
