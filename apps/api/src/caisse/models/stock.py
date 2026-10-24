from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.domain.enums import StockArticleCategory, StockMovementType, StockOutMode
from caisse.models.base import TimestampMixin, generate_uuid


class StockArticle(Base, TimestampMixin):
    """Article de stock (ingrédient, boisson, emballage…), distinct du produit vendu.
    `quantity` et `avg_cost_xof` ne changent que par un mouvement (`stock_movements`)."""

    __tablename__ = "stock_articles"
    __table_args__ = (CheckConstraint("avg_cost_xof >= 0", name="ck_stock_articles_avg_cost_positive"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    name: Mapped[str] = mapped_column(String(120), unique=True, nullable=False)
    category: Mapped[StockArticleCategory] = mapped_column(String(32), nullable=False)
    unit: Mapped[str] = mapped_column(String(16), nullable=False)
    out_mode: Mapped[StockOutMode] = mapped_column(String(32), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal(0), nullable=False)
    avg_cost_xof: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal(0), nullable=False)  # CMP
    alert_threshold: Mapped[Decimal | None] = mapped_column(Numeric(12, 3), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    note: Mapped[str | None] = mapped_column(String(255), nullable=True)

    movements: Mapped[list["StockMovement"]] = relationship("StockMovement", back_populates="article")


class ProductComponent(Base):
    """Ligne de fiche technique : un plat vendu consomme `quantity` de l'article."""

    __tablename__ = "product_components"
    __table_args__ = (
        UniqueConstraint("product_id", "article_id", name="uq_product_components_product_article"),
        CheckConstraint("quantity > 0", name="ck_product_components_quantity_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    product_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("products.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    article_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)

    product = relationship("Product")
    article = relationship("StockArticle")


class StockMovement(Base):
    """Journal du stock, jamais modifié : la quantité d'un article est la somme de ses
    mouvements. `unit_cost_xof` valorise le mouvement (prix payé à l'achat, CMP sinon)."""

    __tablename__ = "stock_movements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    article_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    type: Mapped[StockMovementType] = mapped_column(String(32), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)  # signée
    quantity_after: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    unit_cost_xof: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    business_date: Mapped[date] = mapped_column(Date, index=True, nullable=False)
    reference_order_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("orders.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    reference_order_item_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("order_items.id", ondelete="RESTRICT"), nullable=True
    )
    supplier: Mapped[str | None] = mapped_column(String(120), nullable=True)
    reason: Mapped[str | None] = mapped_column(String(255), nullable=True)
    user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        nullable=False,
    )

    article = relationship("StockArticle", back_populates="movements")
    user = relationship("User")
    order = relationship("Order")


# Alias pour rétrocompatibilité
StockItem = StockArticle

