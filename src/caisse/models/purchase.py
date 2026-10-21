import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from caisse.domain.enums import PurchaseStatus
from caisse.models.base import Base, Timestamps, UUIDPk, enum_column


class PurchaseRequest(UUIDPk, Timestamps, Base):
    """Demande d'achat : l'acheteur saisit des quantités, un responsable valide, décaisse,
    puis réceptionne (entrées de stock). Les montants ne sont jamais montrés ligne à ligne à
    l'acheteur : seulement le total qui lui est remis."""

    __tablename__ = "purchase_requests"

    number: Mapped[str] = mapped_column(String(16), unique=True)
    status: Mapped[PurchaseStatus] = mapped_column(
        enum_column(PurchaseStatus, "purchase_status"), default=PurchaseStatus.SUBMITTED, index=True
    )
    requested_by_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), index=True
    )
    note: Mapped[str | None] = mapped_column(String(255))
    # au dernier prix d'achat, figé à l'envoi
    estimated_total_xof: Mapped[int]
    approved_total_xof: Mapped[int | None]
    approved_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    disbursed_xof: Mapped[int | None]
    disbursed_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    disbursed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    received_total_xof: Mapped[int | None]
    received_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    supplier: Mapped[str | None] = mapped_column(String(120))
    # refus par un responsable, ou retrait par l'acheteur
    closed_reason: Mapped[str | None] = mapped_column(String(255))
    closed_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class PurchaseRequestLine(UUIDPk, Base):
    __tablename__ = "purchase_request_lines"
    __table_args__ = (
        UniqueConstraint("request_id", "article_id", name="uq_purchase_request_lines_article"),
        CheckConstraint("requested_quantity > 0", name="requested_quantity_positive"),
    )

    request_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("purchase_requests.id", ondelete="RESTRICT"), index=True
    )
    article_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("stock_articles.id", ondelete="RESTRICT"), index=True
    )
    requested_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    # null tant que la demande n'est pas validée ; 0 : ligne retirée à la validation
    approved_quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    unit_price_xof: Mapped[Decimal] = mapped_column(Numeric(12, 2))
    # réception : 0 si l'article n'a pas été trouvé
    received_quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    received_cost_xof: Mapped[int | None]
    stock_movement_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("stock_movements.id", ondelete="RESTRICT")
    )
