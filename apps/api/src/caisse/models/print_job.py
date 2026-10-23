from datetime import datetime, timezone
from sqlalchemy import Boolean, DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class PrintJob(Base, TimestampMixin):
    __tablename__ = "print_jobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    order_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("orders.id"), nullable=True)

    job_type: Mapped[str] = mapped_column(String(30), default="RECEIPT", nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="QUEUED", nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)

    open_drawer: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    cut: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_duplicate: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    printed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Pris par l'agent d'un terminal (passage en PRINTING)
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    terminal_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("print_terminals.id", ondelete="SET NULL"), nullable=True
    )
    attempts: Mapped[int] = mapped_column(default=0, nullable=False)

    # Relationships
    order = relationship("Order")
    terminal = relationship("PrintTerminal", foreign_keys=[terminal_id])
