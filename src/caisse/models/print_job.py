import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, ForeignKey, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from caisse.domain.enums import PrintJobStatus, PrintJobType
from caisse.models.base import Base, Timestamps, UUIDPk, enum_column


class PrintJob(UUIDPk, Timestamps, Base):
    __tablename__ = "print_jobs"

    type: Mapped[PrintJobType] = mapped_column(enum_column(PrintJobType, "print_job_type"))
    order_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("orders.id", ondelete="RESTRICT"), index=True
    )
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("cash_sessions.id", ondelete="RESTRICT")
    )
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB)
    rendered: Mapped[str | None] = mapped_column(Text)
    open_drawer: Mapped[bool] = mapped_column(default=False)
    status: Mapped[PrintJobStatus] = mapped_column(
        enum_column(PrintJobStatus, "print_job_status"), default=PrintJobStatus.QUEUED, index=True
    )
    attempts: Mapped[int] = mapped_column(default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    is_reprint: Mapped[bool] = mapped_column(default=False)
    requested_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    # pris par l'agent d'un terminal (passage en PRINTING) ; il rend ensuite le résultat
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    terminal_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("print_terminals.id", ondelete="RESTRICT")
    )
