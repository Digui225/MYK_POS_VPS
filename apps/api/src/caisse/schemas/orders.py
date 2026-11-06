from typing import Literal

from pydantic import Field

from caisse.schemas.common import BaseRequestSchema, BaseSchema

ServiceModeName = Literal["SUR_PLACE", "EMPORTER", "LIVRAISON"]


class OrderItemResponse(BaseSchema):
    id: str
    product_id: str | None = None
    product_name_snapshot: str
    category_snapshot: str
    unit_price_xof: int
    quantity: int
    vat_rate: float
    line_total_xof: int
    note: str | None = None
    seat: int | None = None
    dispatch_no: int | None = None
    added_at: str
    removed_at: str | None = None
    removal_reason: str | None = None


class OrderResponse(BaseSchema):
    id: str
    order_number: str
    cash_session_id: str
    table_id: str | None = None
    table_label: str | None = None
    note_label: str | None = None
    status: Literal["OPEN", "PARTIALLY_PAID", "PAID", "CANCELLED", "REFUNDED"]
    service_mode: ServiceModeName = "SUR_PLACE"
    served_by_user_id: str | None = None
    served_by_name: str | None = None
    dispatch_count: int = 0
    bill_requested_at: str | None = None
    guests_count: int = 1
    total_ttc_xof: int = 0
    total_ht_xof: int = 0
    total_vat_xof: int = 0
    paid_xof: int = 0
    due_xof: int = 0
    items: list[OrderItemResponse] = []
    opened_at: str
    paid_at: str | None = None
    cancelled_reason: str | None = None


class OrderCreateRequest(BaseRequestSchema):
    table_id: str | None = None
    guests_count: int = 1
    note_label: str | None = None
    allow_multiple: bool | None = False
    service_mode: ServiceModeName | None = Field(
        None,
        description="SUR_PLACE (table obligatoire), EMPORTER ou LIVRAISON (sans table). "
        "Absent : SUR_PLACE avec une table, EMPORTER sans table.",
    )


class OrderItemAddRequest(BaseRequestSchema):
    product_id: str | None = None
    custom_name: str | None = None
    unit_price_xof: int | None = None
    quantity: int = Field(1, ge=1)
    note: str | None = None
    category_id: str | None = None
    category_name: str | None = None
    seat: int | None = Field(None, ge=0, description="Convive : 0 = pour la table, 1..n = convive")


class OrderDispatchRequest(BaseRequestSchema):
    """Envoi en cuisine : toutes les lignes sont enregistrées ensemble, ou aucune."""

    items: list[OrderItemAddRequest] = Field(..., min_length=1, max_length=100)


class OrderDispatchResponse(BaseSchema):
    order: OrderResponse
    dispatch_no: int
    kitchen_lines_count: int = Field(description="Lignes parties sur le bon cuisine (boissons exclues)")
    kitchen_ticket_job_id: str | None = Field(None, description="Bon cuisine mis en file d'impression (caisse)")


class BestSellerResponse(BaseSchema):
    product_id: str
    quantity_sold: int


class OrderItemRemoveRequest(BaseRequestSchema):
    reason: str = Field(..., min_length=3)


class OrderCancelRequest(BaseRequestSchema):
    reason: str = Field(..., min_length=3)
