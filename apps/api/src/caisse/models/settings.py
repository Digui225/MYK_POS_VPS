from datetime import datetime
from typing import Any

from sqlalchemy import JSON, DateTime, Float, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from caisse.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class EstablishmentSetting(Base, TimestampMixin):
    __tablename__ = "establishment_settings"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    restaurant_name: Mapped[str] = mapped_column(String(100), default="Restaurant MYK", nullable=False)
    ncc: Mapped[str] = mapped_column(String(50), default="1234567A", nullable=False)
    rccm: Mapped[str] = mapped_column(String(50), default="CI-ABJ-2026-B-0000", nullable=False)
    address: Mapped[str] = mapped_column(String(255), default="Abidjan, Côte d'Ivoire", nullable=False)
    phone: Mapped[str] = mapped_column(String(50), default="+225 0102030405", nullable=False)
    default_vat_rate: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    receipt_footer: Mapped[str] = mapped_column(String(255), default="Merci de votre visite et à très bientôt !", nullable=False)
    print_width: Mapped[int] = mapped_column(Integer, default=48, nullable=False)
    screen_lock_timeout_seconds: Mapped[int] = mapped_column(Integer, default=120, nullable=False)


class AppSetting(Base):
    """Paramètres métier clé-valeur (mentions du ticket, TVA, seuils FNE…)."""

    __tablename__ = "settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[Any] = mapped_column(JSON, nullable=True)
    updated_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SequenceCounter(Base):
    """Compteurs verrouillés par SELECT ... FOR UPDATE (n° de demande d'achat, etc.)."""

    __tablename__ = "sequence_counters"

    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    value: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

