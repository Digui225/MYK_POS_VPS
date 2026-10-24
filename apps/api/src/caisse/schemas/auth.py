from datetime import datetime
from typing import Literal

from pydantic import Field

from caisse.schemas.common import BaseRequestSchema, BaseSchema


class LoginRequest(BaseRequestSchema):
    pin: str = Field(..., min_length=4, max_length=6, description="Code PIN numérique (4 à 6 chiffres)")
    device_id: str = Field(..., description="Identifiant unique du poste caisse")


class UserResponse(BaseSchema):
    id: str
    full_name: str
    role: Literal["CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME"]
    is_active: bool = True
    last_login_at: datetime | None = None


class CreateUserRequest(BaseRequestSchema):
    full_name: str = Field(..., min_length=2, max_length=100, description="Nom complet de l'utilisateur")
    role: Literal["CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME"] = Field("CAISSIER", description="Rôle système de l'utilisateur")
    pin: str = Field(..., min_length=4, max_length=6, description="Code PIN numérique (4 à 6 chiffres)")


class UpdateUserRequest(BaseRequestSchema):
    full_name: str | None = Field(None, min_length=2, max_length=100, description="Nom complet mis à jour")
    role: Literal["CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME"] | None = Field(None, description="Rôle système mis à jour")
    is_active: bool | None = Field(None, description="Statut actif / désactivé")


class ResetPinRequest(BaseRequestSchema):
    new_pin: str = Field(..., min_length=4, max_length=6, description="Nouveau code PIN numérique (4 à 6 chiffres)")


class OpenSessionInfo(BaseSchema):
    id: str
    business_date: str
    cash_register_id: str


class LoginResponse(BaseSchema):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = 900
    user: UserResponse
    open_session: OpenSessionInfo | None = None


class RefreshTokenRequest(BaseRequestSchema):
    refresh_token: str


class RefreshTokenResponse(BaseSchema):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = 900


class OverrideRequest(BaseRequestSchema):
    manager_pin: str = Field(..., min_length=4, max_length=6)
    reason: str = Field(..., min_length=3)
    target_action: str


class OverrideResponse(BaseSchema):
    override_token: str
    expires_in: int = 60
    authorized_by: str
