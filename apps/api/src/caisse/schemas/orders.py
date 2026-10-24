from typing import Literal

from pydantic import Field

from caisse.schemas.common import BaseRequestSchema, BaseSchema


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


class OrderItemAddRequest(BaseRequestSchema):
    product_id: str | None = None
    custom_name: str | None = None
    unit_price_xof: int | None = None
    quantity: int = Field(1, ge=1)
    note: str | None = None


class OrderItemRemoveRequest(BaseRequestSchema):
    reason: str = Field(..., min_length=3)


class OrderCancelRequest(BaseRequestSchema):
    reason: str = Field(..., min_length=3)
