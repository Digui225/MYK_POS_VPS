from pydantic import BaseModel, Field

from caisse.schemas.common import BaseSchema


class EstablishmentSettingsResponse(BaseSchema):
    restaurant_name: str = "Restaurant MYK"
    ncc: str = "1234567A"
    rccm: str = "CI-ABJ-2026-B-0000"
    address: str = "Abidjan, Côte d'Ivoire"
    phone: str = "+225 0102030405"
    default_vat_rate: float = 0.0
    receipt_footer: str = "Merci de votre visite et à très bientôt !"
    print_width: int = 48
    screen_lock_timeout_seconds: int = 120


class UpdateEstablishmentSettingsRequest(BaseModel):
    restaurant_name: str | None = Field(None, min_length=1, max_length=100)
    ncc: str | None = Field(None, min_length=1, max_length=50)
    rccm: str | None = Field(None, max_length=50)
    address: str | None = Field(None, max_length=255)
    phone: str | None = Field(None, max_length=50)
    default_vat_rate: float | None = Field(None, ge=0, le=100)
    receipt_footer: str | None = Field(None, max_length=255)
    print_width: int | None = Field(None, description="Largeur papier thermique en mm (58 ou 80) ou colonnes (32 ou 42)")


class CashRegisterResponse(BaseSchema):
    id: str
    name: str
    is_active: bool = True
    has_active_session: bool = False
    active_session_user: str | None = None
    active_session_opened_at: str | None = None


class CreateCashRegisterRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=50, description="Nom du poste de caisse (ex: Caisse Bar, Caisse Terrasse)")


class UpdateCashRegisterRequest(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=50)
    is_active: bool | None = None
