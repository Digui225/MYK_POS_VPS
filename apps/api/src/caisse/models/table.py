from sqlalchemy import Boolean, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from caisse.core.database import Base
from caisse.models.base import TimestampMixin, generate_uuid


class RestaurantTable(Base, TimestampMixin):
    __tablename__ = "restaurant_tables"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    label: Mapped[str] = mapped_column(String(50), nullable=False, unique=True)
    zone: Mapped[str] = mapped_column(String(50), default="Salle", nullable=False)
    seats: Mapped[int] = mapped_column(Integer, default=4, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
