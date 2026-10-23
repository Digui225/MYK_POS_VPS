from typing import Literal
from pydantic import BaseModel, Field
from caisse.schemas.common import BaseSchema


class CategoryResponse(BaseSchema):
    id: str
    name: str
    kind: Literal["FOOD", "DRINK", "OTHER"]
    sort_order: int = 0
    color: str | None = None
    fiscal_group: str | None = None
    is_active: bool = True


class CategoryCreateRequest(BaseModel):
    name: str
    kind: Literal["FOOD", "DRINK", "OTHER"]
    sort_order: int = 0
    color: str | None = None
    fiscal_group: str | None = None


class CategoryUpdateRequest(BaseModel):
    name: str | None = None
    kind: Literal["FOOD", "DRINK", "OTHER"] | None = None
    sort_order: int | None = None
    color: str | None = None
    fiscal_group: str | None = None
    is_active: bool | None = None


class ProductResponse(BaseSchema):
    id: str
    category_id: str
    name: str
    short_name: str
    price_xof: int
    vat_rate: float = 0.00
    track_stock: bool = False
    stock_quantity: float | None = None
    is_custom: bool = False
    is_active: bool = True
    sort_order: int = 0
    color: str | None = None
    sku: str | None = None


class ProductCreateRequest(BaseModel):
    category_id: str
    name: str
    short_name: str | None = Field(default=None, max_length=20)
    price_xof: int = Field(..., ge=0)
    vat_rate: float = 0.00
    track_stock: bool = False
    color: str | None = None
    sku: str | None = None


class ProductPriceUpdateRequest(BaseModel):
    new_price_xof: int = Field(..., ge=0)
    reason: str = Field(..., min_length=3)
