from typing import Literal

from pydantic import BaseModel, Field

from caisse.domain.floor_plan_rules import GRID_COLUMNS, MAX_ROWS, MAX_TABLE_SPAN
from caisse.schemas.common import BaseSchema

TableShapeName = Literal["ROUND", "RECT"]


class TableResponse(BaseSchema):
    id: str
    label: str
    zone: str = "Salle"
    seats: int = 4
    sort_order: int = 0
    is_active: bool = True
    plan_x: int | None = None
    plan_y: int | None = None
    plan_w: int = 2
    plan_h: int = 2
    shape: TableShapeName = "RECT"


class CreateTableRequest(BaseModel):
    label: str = Field(..., min_length=1, max_length=50, description="Nom ou numéro de la table")
    zone: str = Field("Salle", min_length=1, max_length=50, description="Zone du restaurant (ex: Salle, Terrasse)")
    seats: int = Field(4, ge=1, le=50, description="Nombre de places assises / capacité en personnes")
    sort_order: int = Field(0, description="Ordre d'affichage")


class UpdateTableRequest(BaseModel):
    label: str | None = Field(None, min_length=1, max_length=50, description="Nom ou numéro mis à jour")
    zone: str | None = Field(None, min_length=1, max_length=50, description="Zone mise à jour")
    seats: int | None = Field(None, ge=1, le=50, description="Nombre de places mis à jour")
    sort_order: int | None = Field(None, description="Ordre d'affichage")
    is_active: bool | None = Field(None, description="Statut actif / archivé")


class TablePlacement(BaseModel):
    table_id: str = Field(..., min_length=1, max_length=36)
    zone: str = Field(..., min_length=1, max_length=50, description="Zone dont le plan reçoit la table")
    plan_x: int | None = Field(
        None, ge=0, lt=GRID_COLUMNS, description="Colonne de la case haut-gauche ; nulle = retirée du plan"
    )
    plan_y: int | None = Field(None, ge=0, lt=MAX_ROWS, description="Ligne de la case haut-gauche")
    plan_w: int = Field(2, ge=1, le=MAX_TABLE_SPAN, description="Largeur en cases")
    plan_h: int = Field(2, ge=1, le=MAX_TABLE_SPAN, description="Hauteur en cases")
    shape: TableShapeName = "RECT"


class TablePlanUpdateRequest(BaseModel):
    placements: list[TablePlacement] = Field(..., min_length=1, max_length=200)


class TableOrderItemSummary(BaseSchema):
    name: str
    quantity: int
    line_total_xof: int
    unit_price_xof: int | None = None
    note: str | None = None


class TableActiveOrder(BaseSchema):
    order_id: str
    order_number: str
    note_label: str | None = None
    total_ttc_xof: int = 0
    guests_count: int = 1
    opened_at: str | None = None
    server_name: str | None = None
    served_by_user_id: str | None = None
    dispatch_count: int = 0
    last_dispatch_at: str | None = None
    bill_requested_at: str | None = None
    items_count: int = 0
    service_step: str | None = None
    items_summary: list[TableOrderItemSummary] = []


class TableBoardItem(BaseSchema):
    id: str
    label: str
    zone: str
    seats: int
    is_occupied: bool
    current_order_id: str | None = None
    current_order_number: str | None = None
    current_total_ttc_xof: int = 0
    guests_count: int | None = None
    opened_at: str | None = None
    server_name: str | None = None
    items_count: int | None = None
    service_step: str | None = None
    items_summary: list[TableOrderItemSummary] = []
    active_orders_count: int = 0
    active_orders: list[TableActiveOrder] = []
    bill_requested: bool = False
    plan_x: int | None = None
    plan_y: int | None = None
    plan_w: int = 2
    plan_h: int = 2
    shape: TableShapeName = "RECT"


class TableBoardResponse(BaseSchema):
    tables: list[TableBoardItem]
    open_orders_count: int
    total_in_progress_xof: int
