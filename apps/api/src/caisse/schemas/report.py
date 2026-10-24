from typing import Optional

from pydantic import BaseModel, Field


class TopProductReport(BaseModel):
    product_id: str
    product_name: str
    category_name: Optional[str] = None
    quantity_sold: float
    total_revenue_xof: int


class PaymentMethodSplit(BaseModel):
    method: str
    provider: Optional[str] = None
    count: int
    total_amount_xof: int


class HourlySalesItem(BaseModel):
    hour: str
    total_sales_xof: int
    orders_count: int


class ClosingStatusResponse(BaseModel):
    is_closed: bool
    closed_at: Optional[str] = None
    closed_by_name: Optional[str] = None
    session_id: Optional[str] = None
    z_number: Optional[int] = None


class CashierSalesResponse(BaseModel):
    cashier_name: str
    orders_count: int
    total_sales_ttc_xof: int


class DashboardKpiResponse(BaseModel):
    business_date: str
    total_orders: int
    settled_orders: int
    open_orders: int = 0
    active_tables_count: int = 0
    total_tables_count: int = 14
    dine_in_orders_count: int = 0
    takeaway_orders_count: int = 0
    total_sales_ttc_xof: int
    total_sales_ht_xof: int
    total_sales_vat_xof: int
    average_basket_xof: int
    payments_by_method: list[PaymentMethodSplit]
    top_products: list[TopProductReport]
    hourly_sales: list[HourlySalesItem] = Field(default_factory=list)
    active_sessions_count: int
    low_stock_items_count: int
    fne_certified_count: int
    fne_pending_count: int
    closing_status: Optional[ClosingStatusResponse] = None
    last_x_report_at: Optional[str] = None
    sales_by_cashier: list[CashierSalesResponse] = Field(default_factory=list)


