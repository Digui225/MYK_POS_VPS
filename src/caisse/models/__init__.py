"""Import de tous les modèles : Alembic (autogenerate) et les tests ont besoin du metadata."""

from caisse.models.audit import AuditLog
from caisse.models.base import Base
from caisse.models.cash_session import CashMovement, CashRegister, CashSession
from caisse.models.catalog import Category, Product, ProductPriceHistory
from caisse.models.customer import Customer
from caisse.models.fne import FneDocument
from caisse.models.order import Order, OrderItem
from caisse.models.outbox import OutboxEvent
from caisse.models.payment import Payment
from caisse.models.print_job import PrintJob
from caisse.models.print_terminal import PrintTerminal
from caisse.models.settings import AppSetting, IdempotencyRecord, SequenceCounter
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.models.table import RestaurantTable
from caisse.models.user import DeviceLoginThrottle, OverrideGrant, RefreshToken, User

__all__ = [
    "AppSetting",
    "AuditLog",
    "Base",
    "CashMovement",
    "CashRegister",
    "CashSession",
    "Category",
    "Customer",
    "DeviceLoginThrottle",
    "FneDocument",
    "IdempotencyRecord",
    "Order",
    "OrderItem",
    "OutboxEvent",
    "OverrideGrant",
    "Payment",
    "PrintJob",
    "PrintTerminal",
    "Product",
    "ProductComponent",
    "ProductPriceHistory",
    "RefreshToken",
    "RestaurantTable",
    "SequenceCounter",
    "StockArticle",
    "StockMovement",
    "User",
]
