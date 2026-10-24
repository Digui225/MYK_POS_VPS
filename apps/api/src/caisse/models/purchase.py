from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.domain.enums import PurchaseStatus
from caisse.models.base import TimestampMixin, generate_uuid


class PurchaseRequest(Base, TimestampMixin):
    """Demande d'achat : l'acheteur saisit des quantités, un responsable valide, décaisse,
    puis réceptionne (entrées de stock). Les montants ne sont jamais montrés ligne à ligne à
    l'acheteur : seulement le total qui lui est remis."""

    __tablename__ = "purchase_requests"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    number: Mapped[str] = mapped_column(String(16), unique=True, nullable=False)
    status: Mapped[PurchaseStatus] = mapped_column(
        String(32), default=PurchaseStatus.SUBMITTED, index=True, nullable=False
    )
    requested_by_user_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    note: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # au dernier prix d'achat, figé à l'envoi
    estimated_total_xof: Mapped[int] = mapped_column(Integer, nullable=False)
    approved_total_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    approved_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    disbursed_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    disbursed_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    disbursed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    received_total_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    received_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    supplier: Mapped[str | None] = mapped_column(String(120), nullable=True)
    # refus par un responsable, ou retrait par l'acheteur
    closed_reason: Mapped[str | None] = mapped_column(String(255), nullable=True)
    closed_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    requested_by = relationship("User", foreign_keys=[requested_by_user_id])
    approved_by = relationship("User", foreign_keys=[approved_by_user_id])
    disbursed_by = relationship("User", foreign_keys=[disbursed_by_user_id])
    received_by = relationship("User", foreign_keys=[received_by_user_id])
    closed_by = relationship("User", foreign_keys=[closed_by_user_id])


class PurchaseRequestLine(Base):
    __tablename__ = "purchase_request_lines"
    __table_args__ = (
        UniqueConstraint("request_id", "article_id", name="uq_purchase_request_lines_article"),
        CheckConstraint("requested_quantity > 0", name="ck_purchase_request_lines_requested_quantity_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    request_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("purchase_requests.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    article_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    requested_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    # null tant que la demande n'est pas validée ; 0 : ligne retirée à la validation
    approved_quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3), nullable=True)
    unit_price_xof: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    # réception : 0 si l'article n'a pas été trouvé
    received_quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3), nullable=True)
    received_cost_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    stock_movement_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("stock_movements.id", ondelete="RESTRICT"), nullable=True
    )

    request = relationship("PurchaseRequest")
    article = relationship("StockArticle")
    stock_movement = relationship("StockMovement")
