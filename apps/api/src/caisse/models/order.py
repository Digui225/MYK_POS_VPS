from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, Index, Integer, Numeric, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class Order(Base, TimestampMixin):
    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    order_number: Mapped[str] = mapped_column(String(50), nullable=False, unique=True)
    cash_session_id: Mapped[str] = mapped_column(String(36), ForeignKey("cash_sessions.id"), nullable=False)
    table_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("restaurant_tables.id"), nullable=True)
    note_label: Mapped[str | None] = mapped_column(String(50), nullable=True)

    status: Mapped[str] = mapped_column(String(20), default="OPEN", nullable=False)
    opened_by_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    closed_by_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)

    guests_count: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    total_ttc_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_ht_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_vat_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    paid_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    due_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    cancelled_reason: Mapped[str | None] = mapped_column(String(255), nullable=True)
    cancelled_by_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False)
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Relationships
    cash_session = relationship("CashSession")
    table = relationship("RestaurantTable")
    opened_by = relationship("User", foreign_keys=[opened_by_user_id])
    closed_by = relationship("User", foreign_keys=[closed_by_user_id])
    cancelled_by = relationship("User", foreign_keys=[cancelled_by_user_id])
    items: Mapped[list["OrderItem"]] = relationship("OrderItem", back_populates="order", cascade="all, delete-orphan")
    payments = relationship("Payment", back_populates="order", cascade="all, delete-orphan")

    __table_args__ = (
        Index("ix_orders_table_status", "table_id", "status"),
    )


class OrderItem(Base, TimestampMixin):
    __tablename__ = "order_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    order_id: Mapped[str] = mapped_column(String(36), ForeignKey("orders.id"), nullable=False)
    product_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("products.id"), nullable=True)



    # Snapshots figés au moment de l'ajout (immuabilité)
    product_name_snapshot: Mapped[str] = mapped_column(String(150), nullable=False)
    category_snapshot: Mapped[str] = mapped_column(String(100), nullable=False)
    unit_price_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    vat_rate: Mapped[float] = mapped_column(Numeric(4, 2), default=0.00, nullable=False)
    line_total_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    note: Mapped[str | None] = mapped_column(String(255), nullable=True)

    added_by_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False)



    # Traçabilité des retraits (jamais de DELETE physique)
    removed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    removed_by_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    removal_reason: Mapped[str | None] = mapped_column(String(255), nullable=True)



    # Relationships
    order: Mapped[Order] = relationship("Order", back_populates="items")
    product = relationship("Product")
    added_by = relationship("User", foreign_keys=[added_by_user_id])
    removed_by = relationship("User", foreign_keys=[removed_by_user_id])
