from datetime import date, datetime
from decimal import Decimal
from typing import Self
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from caisse.domain.enums import StockArticleCategory, StockMovementType, StockOutMode
from caisse.schemas.common import ApiWarning, BaseSchema

Quantity = Decimal  # 3 décimales au plus (kg, pièces fractionnées : 0,25 poulet)


def _strip(value: object) -> object:
    return value.strip() if isinstance(value, str) else value


# --- Articles ----------------------------------------------------------------------------


class StockArticleCreate(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "name": "Bœuf",
                    "category": "PROTEINE",
                    "unit": "kg",
                    "out_mode": "RECIPE",
                    "avg_cost_xof": 4000,
                    "alert_threshold": 3,
                }
            ]
        }
    )

    name: str = Field(min_length=1, max_length=120, description="Nom unique de l'article")
    category: StockArticleCategory = Field(description="Famille d'article")
    unit: str = Field(min_length=1, max_length=16, description="Unité : kg, pièce, bouteille…")
    out_mode: StockOutMode = Field(
        description="RECIPE : sorties automatiques depuis les ventes (fiche technique) ; "
        "INVENTORY : consommation déduite des inventaires"
    )
    avg_cost_xof: Decimal = Field(
        default=Decimal(0),
        ge=Decimal(0),
        max_digits=12,
        decimal_places=2,
        description="Coût unitaire de départ ; ensuite recalculé à chaque entrée (CMP)",
    )
    alert_threshold: Quantity | None = Field(
        default=None, ge=Decimal(0), max_digits=12, decimal_places=3, description="Seuil d'alerte"
    )
    note: str | None = Field(default=None, max_length=255, description="Remarque libre")

    _strip_name = field_validator("name", "unit", mode="before")(_strip)


class StockArticleUpdate(BaseModel):
    """Champs modifiables ; la quantité et le coût ne changent que par un mouvement."""

    name: str | None = Field(default=None, min_length=1, max_length=120)
    category: StockArticleCategory | None = None
    unit: str | None = Field(default=None, min_length=1, max_length=16)
    out_mode: StockOutMode | None = None
    alert_threshold: Quantity | None = Field(
        default=None, ge=Decimal(0), max_digits=12, decimal_places=3, description="null : pas d'alerte"
    )
    is_active: bool | None = None
    note: str | None = Field(default=None, max_length=255)

    _strip_name = field_validator("name", "unit", mode="before")(_strip)


class StockArticleOut(BaseSchema):
    id: str = Field(description="Identifiant de l'article")
    name: str = Field(description="Nom", examples=["Bœuf"])
    category: StockArticleCategory = Field(description="Famille d'article")
    unit: str = Field(description="Unité", examples=["kg"])
    out_mode: StockOutMode = Field(description="RECIPE (fiche technique) ou INVENTORY")
    quantity: float = Field(description="Quantité en stock (peut être négative)")
    avg_cost_xof: float = Field(description="Coût moyen pondéré d'une unité")
    value_xof: int = Field(description="Valeur du stock (0 si la quantité est négative)")
    alert_threshold: float | None = Field(description="Seuil d'alerte ; null : aucun")
    is_low: bool = Field(description="Stock négatif ou au plus égal au seuil")
    is_active: bool = Field(description="Article utilisé")
    note: str | None = Field(description="Remarque libre")
    updated_at: datetime = Field(description="Dernière modification")


# --- Fiches techniques -------------------------------------------------------------------


class ComponentIn(BaseModel):
    article_id: str = Field(description="Article consommé")
    quantity: Quantity = Field(
        gt=Decimal(0), max_digits=12, decimal_places=3, description="Quantité par portion vendue"
    )


class ComponentsUpdate(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={"examples": [{"components": [{"article_id": "…", "quantity": 0.2}]}]}
    )

    components: list[ComponentIn] = Field(
        max_length=20, description="Fiche complète ; liste vide : le plat ne déstocke plus"
    )

    @model_validator(mode="after")
    def _unique_articles(self) -> Self:
        ids = [c.article_id for c in self.components]
        if len(ids) != len(set(ids)):
            raise ValueError("un article apparaît deux fois dans la fiche")
        return self


class ComponentOut(BaseSchema):
    article_id: str = Field(description="Article consommé")
    article_name: str = Field(description="Nom de l'article")
    unit: str = Field(description="Unité de l'article")
    quantity: float = Field(description="Quantité par portion vendue")
    unit_cost_xof: float = Field(description="Coût moyen actuel d'une unité de l'article")
    cost_xof: float = Field(description="Coût matière de ce composant pour une portion")


class ProductComponentsOut(BaseSchema):
    product_id: str = Field(description="Plat")
    product_name: str = Field(description="Nom du plat")
    price_xof: int = Field(description="Prix de vente")
    components: list[ComponentOut] = Field(description="Fiche technique")
    cost_xof: float = Field(description="Coût matière d'une portion au CMP actuel")
    margin_xof: float = Field(description="Prix de vente - coût matière")


# --- Saisies -----------------------------------------------------------------------------


class _Operation(BaseModel):
    business_date: date | None = Field(
        default=None, description="Journée concernée ; défaut : journée de la session ouverte"
    )

    @model_validator(mode="after")
    def _unique_articles(self) -> Self:
        ids = [line.article_id for line in getattr(self, "lines", [])]
        if len(ids) != len(set(ids)):
            raise ValueError("un article apparaît deux fois")
        return self


class ReceiptLine(BaseModel):
    article_id: str = Field(description="Article reçu")
    quantity: Quantity = Field(gt=Decimal(0), max_digits=12, decimal_places=3, description="Quantité reçue")
    total_cost_xof: int | None = Field(
        default=None, ge=0, description="Montant payé pour la ligne (ou `unit_cost_xof`)"
    )
    unit_cost_xof: Decimal | None = Field(
        default=None, ge=Decimal(0), max_digits=12, decimal_places=2, description="Prix d'une unité"
    )

    @model_validator(mode="after")
    def _one_cost(self) -> Self:
        if (self.total_cost_xof is None) == (self.unit_cost_xof is None):
            raise ValueError("indiquer total_cost_xof ou unit_cost_xof (un seul des deux)")
        return self


class StockReceiptCreate(_Operation):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "supplier": "Marché de Cocody",
                    "lines": [
                        {"article_id": "…", "quantity": 10, "total_cost_xof": 40000},
                        {"article_id": "…", "quantity": 24, "unit_cost_xof": 250},
                    ],
                }
            ]
        }
    )

    supplier: str | None = Field(default=None, max_length=120, description="Fournisseur")
    reason: str | None = Field(default=None, max_length=255, description="Remarque")
    lines: list[ReceiptLine] = Field(min_length=1, max_length=100, description="Articles reçus")


class LossLine(BaseModel):
    article_id: str = Field(description="Article perdu")
    quantity: Quantity = Field(gt=Decimal(0), max_digits=12, decimal_places=3, description="Quantité")


class StockLossCreate(_Operation):
    reason: str = Field(
        min_length=1, max_length=255, description="Motif : avarié, cassé, repas du personnel…"
    )
    lines: list[LossLine] = Field(min_length=1, max_length=100, description="Articles perdus")


class CountLine(BaseModel):
    article_id: str = Field(description="Article compté")
    counted_quantity: Quantity = Field(
        ge=Decimal(0), max_digits=12, decimal_places=3, description="Quantité réellement présente"
    )


class StockCountCreate(_Operation):
    reason: str | None = Field(default=None, max_length=255, description="Remarque")
    lines: list[CountLine] = Field(min_length=1, max_length=300, description="Comptage")


# --- Mouvements --------------------------------------------------------------------------


class StockMovementOut(BaseSchema):
    id: str = Field(description="Identifiant du mouvement")
    article_id: str = Field(description="Article")
    article_name: str = Field(description="Nom de l'article")
    type: StockMovementType = Field(description="Nature du mouvement")
    quantity: float = Field(description="Quantité signée (+ entrée, - sortie)")
    quantity_after: float = Field(description="Stock de l'article après le mouvement")
    unit_cost_xof: float = Field(description="Coût d'une unité (prix payé ou CMP)")
    value_xof: int = Field(description="Valeur signée du mouvement")
    business_date: date = Field(description="Journée")
    reference_order_id: str | None = Field(default=None, description="Commande à l'origine (vente)")
    supplier: str | None = Field(default=None, description="Fournisseur (entrée)")
    reason: str | None = Field(default=None, description="Motif")
    user_id: str | None = Field(default=None, description="Auteur ; null : import")
    created_at: datetime = Field(description="Horodatage")


class StockOperationOut(BaseSchema):
    movements: list[StockMovementOut] = Field(description="Mouvements créés")
    articles: list[StockArticleOut] = Field(description="Articles après l'opération")
    warnings: list[ApiWarning] = Field(
        default=[], description="`STOCK_NEGATIVE_WARNING` : un article passe sous zéro"
    )


# --- Rétrocompatibilité ---
StockItemResponse = StockArticleOut
StockMovementResponse = StockMovementOut
class StockMovementRequest(BaseModel):
    product_id: str
    type: str
    quantity: float
    unit_cost_xof: int | None = None
    reason: str

