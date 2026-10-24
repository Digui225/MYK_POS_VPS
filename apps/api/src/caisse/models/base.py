import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime
from sqlalchemy.orm import Mapped, mapped_column

from caisse.database import Base as Base

__all__ = ["Base", "TimestampMixin", "generate_uuid"]


def generate_uuid() -> str:
    """Génère un identifiant unique en chaîne UUID."""
    return str(uuid.uuid4())


class TimestampMixin:
    """Mixin standard ajoutant les horodatages UTC immuables."""
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
        nullable=False,
    )
