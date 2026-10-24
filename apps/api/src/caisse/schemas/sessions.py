from typing import Any, Literal

from pydantic import BaseModel, Field

from caisse.schemas.common import BaseSchema


class SessionOpenRequest(BaseModel):
    cash_register_id: str
    opening_float_xof: int = Field(..., ge=0)
    business_date: str = Field(..., description="Date comptable YYYY-MM-DD")


class CashMovementRequest(BaseModel):
    type: Literal["IN", "OUT"]
    amount_xof: int = Field(..., gt=0)
    reason: str = Field(..., min_length=3)


class CashMovementResponse(BaseSchema):
    id: str
    cash_session_id: str
    type: str
    amount_xof: int
    reason: str
    user_name: str
    created_at: str


class SessionCloseRequest(BaseModel):
    counted_breakdown: dict[str, int] = Field(
        ...,
        description="Comptage par dénomination : {'10000': 12, '5000': 8, ...}"
    )
    notes: str | None = None


class CashSessionResponse(BaseSchema):
    id: str
    cash_register_id: str
    business_date: str
    status: Literal["OPEN", "CLOSING", "CLOSED"]
    opening_float_xof: int
    opened_at: str
    closed_at: str | None = None
    z_number: int | None = None
    expected_cash_xof: int | None = None
    counted_cash_xof: int | None = None
    variance_xof: int | None = None
    totals_snapshot: dict[str, Any] | None = None


class ItemSalesDetail(BaseSchema):
    product_name: str
    category: str
    quantity: int
    unit_price_xof: int
    total_ttc_xof: int


class XReportResponse(BaseSchema):
    cash_session_id: str
    business_date: str
    opened_at: str
    opening_float_xof: int
    total_sales_ttc_xof: int
    total_sales_ht_xof: int
    total_sales_vat_xof: int
    payments_by_method: dict[str, int]
    sales_by_category: dict[str, int]
    sales_by_item: list[ItemSalesDetail] = Field(default_factory=list)
    cash_movements_in_xof: int
    cash_movements_out_xof: int
    expected_cash_in_drawer_xof: int
    orders_count: int
    cancelled_orders_count: int


class ZReportResponse(BaseSchema):
    z_number: int
    cash_session_id: str
    business_date: str
    opened_at: str
    closed_at: str
    opening_float_xof: int
    total_sales_ttc_xof: int
    total_sales_ht_xof: int
    total_sales_vat_xof: int
    payments_by_method: dict[str, int]
    sales_by_category: dict[str, int]
    sales_by_item: list[ItemSalesDetail] = Field(default_factory=list)
    cash_movements_in_xof: int
    cash_movements_out_xof: int
    expected_cash_in_drawer_xof: int
    counted_cash_xof: int
    variance_xof: int
    closing_breakdown: dict[str, int]
    orders_count: int
    cancelled_orders_count: int
    notes: str | None = None
