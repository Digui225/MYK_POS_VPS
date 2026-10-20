import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from caisse.models.base import Base, Timestamps, UUIDPk


class PrintTerminal(UUIDPk, Timestamps, Base):
    """Poste qui imprime : son agent vient chercher les travaux sur l'API avec un jeton propre,
    distinct des PIN. Seule l'empreinte SHA-256 du jeton est stockée."""

    __tablename__ = "print_terminals"

    name: Mapped[str] = mapped_column(String(60), unique=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # mis à jour à chaque interrogation de l'agent : sert d'indicateur « agent en ligne »
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    printer_status: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict)
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
