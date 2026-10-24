from typing import Any, Generic, TypeVar

from pydantic import BaseModel, ConfigDict

T = TypeVar("T")


class BaseSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True, populate_by_name=True)


class BaseRequestSchema(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PaginatedResponse(BaseSchema, Generic[T]):
    items: list[T]
    next_cursor: str | None = None


Page = PaginatedResponse


class HealthResponse(BaseSchema):
    status: str = "ok"
    app: str = "Caisse MYK API"
    environment: str = "development"


class HealthReadyResponse(BaseSchema):
    status: str = "ok"
    database: bool = True
    print_agent: bool = True
    fne_queue_length: int = 0


class ApiWarning(BaseSchema):
    code: str
    detail: str | None = None
    meta: dict[str, Any] = {}

