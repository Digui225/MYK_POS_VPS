from sqlalchemy import Boolean, String
from sqlalchemy.orm import Mapped, mapped_column

from caisse.models.base import Base, TimestampMixin, generate_uuid


class Customer(Base, TimestampMixin):
    __tablename__ = "customers"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    ncc: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)  # Numéro de Compte Contribuable DGI
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)
    email: Mapped[str | None] = mapped_column(String(100), nullable=True)
    address: Mapped[str | None] = mapped_column(String(255), nullable=True)
    tax_regime: Mapped[str | None] = mapped_column(String(50), nullable=True)  # ex. Régime TEE, RSI, RNI
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    @property
    def company_name(self) -> str:
        return self.name

    @company_name.setter
    def company_name(self, value: str) -> None:
        self.name = value

