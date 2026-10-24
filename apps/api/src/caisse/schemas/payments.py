from typing import Any, Literal

from pydantic import Field

from caisse.domain.enums import PaymentMethod
from caisse.schemas.common import BaseRequestSchema, BaseSchema


class PaymentRequest(BaseRequestSchema):
    method: PaymentMethod
    amount_xof: int = Field(..., gt=0)
    tendered_xof: int | None = None
    provider: str | None = None
    reference: str | None = None
    request_fne: bool = False
    customer_id: str | None = None


class PaymentResponse(BaseSchema):
    id: str
    order_id: str
    method: str
    amount_xof: int
    tendered_xof: int | None = None
    change_xof: int | None = None
    provider: str | None = None
    reference: str | None = None
    status: str = "CAPTURED"
    created_at: str


class OrderPaymentResult(BaseSchema):
    payment: PaymentResponse
    order_status: Literal["PARTIALLY_PAID", "PAID"]
    remaining_due_xof: int
    change_xof: int = 0
    drawer_opened: bool = False
    print_job_id: str | None = None
    fne_status: str | None = None
    warnings: list[Any] = []
