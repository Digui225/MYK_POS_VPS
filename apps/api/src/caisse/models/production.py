from datetime import date
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    Date,
    ForeignKey,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class MarketPurchaseList(Base, TimestampMixin):
    """Bon d'achat marché préparé par la caissière avant de faire les courses,
    validé ensuite par le responsable pour mettre à jour les stocks et dépenses."""

    __tablename__ = "market_purchase_lists"
    __table_args__ = (
        CheckConstraint("total_budget_xof >= 0", name="ck_market_purchase_lists_budget_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    business_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    status: Mapped[str] = mapped_column(
        String(20), default="DRAFT", nullable=False, index=True
    )  # DRAFT, COMPLETED, CANCELLED
    created_by_user_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    validated_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    total_budget_xof: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    notes: Mapped[str | None] = mapped_column(String(255), nullable=True)

    items: Mapped[list["MarketPurchaseItem"]] = relationship(
        "MarketPurchaseItem",
        back_populates="purchase_list",
        cascade="all, delete-orphan",
        order_by="MarketPurchaseItem.created_at",
    )
    created_by = relationship("User", foreign_keys=[created_by_user_id])
    validated_by = relationship("User", foreign_keys=[validated_by_user_id])


class MarketPurchaseItem(Base, TimestampMixin):
    """Ligne de bon d'achat marché : quantité estimée et prix unitaire au marché."""

    __tablename__ = "market_purchase_items"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="ck_market_purchase_items_qty_positive"),
        CheckConstraint("unit_price_xof >= 0", name="ck_market_purchase_items_unit_price_positive"),
        CheckConstraint(
            "total_price_xof >= 0", name="ck_market_purchase_items_total_price_positive"
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    purchase_list_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("market_purchase_lists.id", ondelete="CASCADE"),
        index=True,
        nullable=False,
    )
    article_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    unit_price_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    total_price_xof: Mapped[int] = mapped_column(Integer, nullable=False)

    purchase_list: Mapped["MarketPurchaseList"] = relationship(
        "MarketPurchaseList", back_populates="items"
    )
    article = relationship("StockArticle")


class DailyPreparation(Base, TimestampMixin):
    """Sortie de matière première en cuisine le matin pour préparation de plats.
    Ex: 3 poulets sortis avec rendement de 4 plats/poulet = 12 plats prévus."""

    __tablename__ = "daily_preparations"
    __table_args__ = (
        UniqueConstraint("business_date", "article_id", name="uq_daily_prep_date_article"),
        CheckConstraint("prepared_quantity > 0", name="ck_daily_prep_qty_positive"),
        CheckConstraint("yield_portions_per_unit > 0", name="ck_daily_prep_yield_positive"),
        CheckConstraint("theoretical_dishes >= 0", name="ck_daily_prep_dishes_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    business_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    article_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    prepared_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    yield_portions_per_unit: Mapped[Decimal] = mapped_column(Numeric(6, 2), nullable=False)
    theoretical_dishes: Mapped[int] = mapped_column(Integer, nullable=False)
    user_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=False
    )
    notes: Mapped[str | None] = mapped_column(String(255), nullable=True)

    article = relationship("StockArticle")
    user = relationship("User")
