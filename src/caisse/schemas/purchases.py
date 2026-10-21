"""Demandes d'achat. Deux vues de la même demande : celle de l'acheteur (quantités et total à
lui remettre, jamais de prix ligne à ligne) et celle du responsable (tous les montants)."""

import uuid
from datetime import date, datetime
from typing import Self

from pydantic import ConfigDict, Field, model_validator

from caisse.domain.enums import PurchaseStatus, StockArticleCategory
from caisse.schemas.common import Schema, UserOut
from caisse.schemas.stock import Quantity


def _unique(ids: list[uuid.UUID], what: str) -> None:
    if len(ids) != len(set(ids)):
        raise ValueError(f"{what} apparaît deux fois")


# --- Acheteur ----------------------------------------------------------------------------


class PurchaseArticleOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de l'article de stock")
    name: str = Field(description="Nom", examples=["Bœuf"])
    category: StockArticleCategory = Field(description="Famille d'article")
    unit: str = Field(description="Unité d'achat", examples=["kg"])
    quantity: float = Field(description="Quantité en stock (peut être négative)")
    is_low: bool = Field(description="Stock négatif ou au plus égal au seuil d'alerte")


class PurchaseLineIn(Schema):
    article_id: uuid.UUID = Field(description="Article à acheter")
    quantity: Quantity = Field(gt=0, max_digits=12, decimal_places=3, description="Quantité")


class PurchaseCreate(Schema):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "note": "Marché de Treichville",
                    "lines": [
                        {"article_id": "…", "quantity": 5},
                        {"article_id": "…", "quantity": 0.5},
                    ],
                }
            ]
        }
    )

    note: str | None = Field(default=None, max_length=255, description="Remarque libre")
    lines: list[PurchaseLineIn] = Field(min_length=1, max_length=150, description="À acheter")

    @model_validator(mode="after")
    def _unique_articles(self) -> Self:
        _unique([line.article_id for line in self.lines], "un article")
        return self


class BuyerLineOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de la ligne")
    article_id: uuid.UUID = Field(description="Article")
    article_name: str = Field(description="Nom de l'article")
    unit: str = Field(description="Unité")
    requested_quantity: float = Field(description="Quantité demandée")
    approved_quantity: float | None = Field(
        description="Quantité validée par le responsable (0 : retirée) ; null avant validation"
    )
    received_quantity: float | None = Field(description="Quantité réceptionnée")


class BuyerPurchaseSummaryOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de la demande")
    number: str = Field(description="Numéro", examples=["ACH-0001"])
    status: PurchaseStatus = Field(description="État de la demande")
    note: str | None = Field(description="Remarque de l'acheteur")
    amount_xof: int = Field(
        description="Montant qui sera remis : total validé, sinon total estimé à l'envoi"
    )
    disbursed_xof: int | None = Field(description="Montant effectivement remis")
    received_total_xof: int | None = Field(description="Total dépensé, saisi à la réception")
    change_due_xof: int | None = Field(
        description="Monnaie à rendre (remis - dépensé) ; négatif : la caisse doit à l'acheteur"
    )
    closed_reason: str | None = Field(description="Motif du refus ou du retrait")
    created_at: datetime = Field(description="Envoi")
    updated_at: datetime = Field(description="Dernière modification")


class BuyerPurchaseOut(BuyerPurchaseSummaryOut):
    lines: list[BuyerLineOut] = Field(description="Articles demandés")


class PurchaseCancel(Schema):
    reason: str | None = Field(default=None, max_length=255, description="Motif du retrait")


# --- Responsable -------------------------------------------------------------------------


class PurchaseLineOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de la ligne")
    article_id: uuid.UUID = Field(description="Article")
    article_name: str = Field(description="Nom de l'article")
    category: StockArticleCategory = Field(description="Famille d'article")
    unit: str = Field(description="Unité")
    requested_quantity: float = Field(description="Quantité demandée")
    approved_quantity: float | None = Field(description="Quantité validée (0 : ligne retirée)")
    unit_price_xof: float = Field(
        description="Prix d'une unité : dernier prix d'achat à l'envoi, ou corrigé à la validation"
    )
    price_missing: bool = Field(
        description="Aucun prix connu (0) : la ligne ne compte pas dans le montant à remettre"
    )
    amount_xof: int = Field(description="Quantité (validée, sinon demandée) x prix")
    received_quantity: float | None = Field(description="Quantité réceptionnée")
    received_cost_xof: int | None = Field(description="Montant payé pour la ligne")


class PurchaseSummaryOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de la demande")
    number: str = Field(description="Numéro", examples=["ACH-0001"])
    status: PurchaseStatus = Field(description="État de la demande")
    requested_by: UserOut = Field(description="Acheteur")
    note: str | None = Field(description="Remarque de l'acheteur")
    estimated_total_xof: int = Field(description="Total au dernier prix d'achat, à l'envoi")
    approved_total_xof: int | None = Field(description="Total après validation")
    approved_by: UserOut | None = Field(description="Responsable qui a validé")
    approved_at: datetime | None = Field(description="Validation")
    disbursed_xof: int | None = Field(description="Montant remis à l'acheteur")
    disbursed_by: UserOut | None = Field(description="Responsable qui a remis l'argent")
    disbursed_at: datetime | None = Field(description="Décaissement")
    received_total_xof: int | None = Field(description="Total dépensé (somme des lignes reçues)")
    received_by: UserOut | None = Field(description="Responsable qui a réceptionné")
    received_at: datetime | None = Field(description="Réception")
    supplier: str | None = Field(description="Fournisseur ou marché, saisi à la réception")
    change_due_xof: int | None = Field(
        description="Monnaie à rendre (remis - dépensé) ; négatif : la caisse doit à l'acheteur"
    )
    closed_reason: str | None = Field(description="Motif du refus ou du retrait")
    closed_by: UserOut | None = Field(description="Auteur du refus ou du retrait")
    closed_at: datetime | None = Field(description="Refus ou retrait")
    line_count: int = Field(description="Nombre de lignes")
    created_at: datetime = Field(description="Envoi")
    updated_at: datetime = Field(description="Dernière modification")


class PurchaseOut(PurchaseSummaryOut):
    lines: list[PurchaseLineOut] = Field(description="Articles demandés")


class ApproveLine(Schema):
    line_id: uuid.UUID = Field(description="Ligne corrigée")
    quantity: Quantity | None = Field(
        default=None, ge=0, max_digits=12, decimal_places=3, description="0 : ligne retirée"
    )
    unit_price_xof: Quantity | None = Field(
        default=None, ge=0, max_digits=12, decimal_places=2, description="Prix d'une unité"
    )


class PurchaseApprove(Schema):
    lines: list[ApproveLine] = Field(
        default=[],
        max_length=150,
        description="Corrections ; une ligne absente est validée telle que demandée",
    )

    @model_validator(mode="after")
    def _unique_lines(self) -> Self:
        _unique([line.line_id for line in self.lines], "une ligne")
        return self


class PurchaseReject(Schema):
    reason: str = Field(min_length=1, max_length=255, description="Motif du refus")


class PurchaseDisburse(Schema):
    amount_xof: int | None = Field(
        default=None, gt=0, description="Montant remis ; défaut : total validé"
    )


class ReceiveLine(Schema):
    line_id: uuid.UUID = Field(description="Ligne de la demande")
    quantity: Quantity = Field(
        ge=0, max_digits=12, decimal_places=3, description="Quantité achetée (0 : pas trouvé)"
    )
    total_cost_xof: int = Field(ge=0, description="Montant payé pour la ligne")


class PurchaseReceive(Schema):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "supplier": "Marché de Treichville",
                    "lines": [{"line_id": "…", "quantity": 5, "total_cost_xof": 21000}],
                }
            ]
        }
    )

    business_date: date | None = Field(
        default=None, description="Journée des entrées de stock ; défaut : session ouverte"
    )
    supplier: str | None = Field(default=None, max_length=120, description="Fournisseur")
    lines: list[ReceiveLine] = Field(
        min_length=1,
        max_length=150,
        description="Ce qui a été acheté ; une ligne validée absente compte comme non trouvée",
    )

    @model_validator(mode="after")
    def _unique_lines(self) -> Self:
        _unique([line.line_id for line in self.lines], "une ligne")
        for line in self.lines:
            if line.quantity == 0 and line.total_cost_xof:
                raise ValueError("montant payé pour une quantité nulle")
        return self


class PurchasePendingOut(Schema):
    submitted: int = Field(description="À valider")
    approved: int = Field(description="Validées, à décaisser")
    disbursed: int = Field(description="Argent remis, à réceptionner")
