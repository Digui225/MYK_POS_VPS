"""Package transverse pour la configuration, la base de données, la sécurité et la plomberie FastAPI."""

from caisse.core.config import Settings, get_settings
from caisse.core.database import Base, SessionLocal, engine, get_db
from caisse.core.errors import (
    CaisseException,
    CustomerNccExistsError,
    FneDocumentStateError,
    FneInvalidDataError,
    FneNotConfiguredError,
    FneOrderNotPaidError,
    FneRefundExceedsError,
    IdempotencyConflictError,
    MarketBudgetExceededError,
    NotFoundError,
    PurchaseStateError,
    StockArticleNameExistsError,
    ValidationError,
    caisse_exception_handler,
    problem_json_response,
    unhandled_exception_handler,
    validation_exception_handler,
)

__all__ = [
    "Base",
    "CaisseException",
    "CustomerNccExistsError",
    "FneDocumentStateError",
    "FneInvalidDataError",
    "FneNotConfiguredError",
    "FneOrderNotPaidError",
    "FneRefundExceedsError",
    "IdempotencyConflictError",
    "MarketBudgetExceededError",
    "NotFoundError",
    "PurchaseStateError",
    "SessionLocal",
    "Settings",
    "StockArticleNameExistsError",
    "ValidationError",
    "caisse_exception_handler",
    "engine",
    "get_db",
    "get_settings",
    "problem_json_response",
    "unhandled_exception_handler",
    "validation_exception_handler",
]
