from datetime import datetime
from typing import Any

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    false,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.domain.enums import FneDocumentType, FneStatus
from caisse.models.base import Base, TimestampMixin, generate_uuid


class FneDocument(Base, TimestampMixin):
    __tablename__ = "fne_documents"
    __table_args__ = (
        Index(
            "ix_fne_documents_retry",
            "next_retry_at",
            sqlite_where=text("status = 'QUEUED'"),
            postgresql_where=text("status = 'QUEUED'"),
        ),
        # une seule FNE de vente par commande : pas de double certification
        Index(
            "uq_fne_documents_one_sale_per_order",
            "order_id",
            unique=True,
            sqlite_where=text("type = 'FNE'"),
            postgresql_where=text("type = 'FNE'"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    type: Mapped[str] = mapped_column(String(20), default=FneDocumentType.FNE, nullable=False)
    order_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("orders.id", ondelete="RESTRICT"), nullable=True, index=True
    )
    cash_session_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("cash_sessions.id", ondelete="RESTRICT"), nullable=True
    )
    customer_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("customers.id", ondelete="RESTRICT"), nullable=True, index=True
    )
    status: Mapped[str] = mapped_column(
        String(20), default=FneStatus.PENDING, index=True, nullable=False
    )
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)  # snapshot figé
    external_number: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    qr_payload: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_response: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    certified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    next_retry_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # B2C / B2B / B2G / B2F
    template: Mapped[str | None] = mapped_column(String(8), nullable=True)
    # avoir → FNE d'origine
    parent_document_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("fne_documents.id", ondelete="RESTRICT"), nullable=True, index=True
    )
    # identifiant FNE de la facture (`invoice.id`), requis pour un avoir
    fne_invoice_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # [{"order_item_id", "fne_item_id", "quantity"}] : lignes certifiées, pour les avoirs
    items_map: Mapped[list[dict[str, Any]] | None] = mapped_column(JSON, nullable=True)
    fne_amount_ttc_xof: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sticker_balance: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # issue inconnue (délai dépassé, 500…) : jamais de renvoi automatique
    is_uncertain: Mapped[bool] = mapped_column(Boolean, default=False, server_default=false(), nullable=False)
    created_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="RESTRICT"), nullable=True
    )

    # Propriétés de compatibilité ascendante
    @property
    def invoice_number(self) -> str | None:
        return self.external_number

    @property
    def document_type(self) -> str:
        return self.type

    @property
    def qr_url(self) -> str | None:
        return self.qr_payload

    order = relationship("Order", backref="fne_documents", foreign_keys=[order_id])
    customer = relationship("Customer", backref="fne_documents", foreign_keys=[customer_id])
    parent_document = relationship("FneDocument", remote_side=[id], backref="refund_documents")
