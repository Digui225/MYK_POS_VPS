from datetime import datetime
from typing import Literal

from pydantic import Field

from caisse.schemas.common import BaseRequestSchema, BaseSchema

RoleName = Literal["CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME", "SERVEUR"]


class LoginRequest(BaseRequestSchema):
    pin: str = Field(..., min_length=4, max_length=6, description="Code PIN numérique (4 à 6 chiffres)")
    device_id: str = Field(..., description="Identifiant unique du poste caisse")
    user_id: str | None = Field(
        None,
        description=(
            "Compte choisi avant le PIN (écran « Qui prend le service ? » des appareils de salle). "
            "Absent : connexion par PIN seul, comme à la caisse."
        ),
    )


class StaffMemberResponse(BaseSchema):
    """Serveur actif proposé sur l'écran de prise de service, avant connexion."""

    id: str
    full_name: str


class UserResponse(BaseSchema):
    id: str
    full_name: str
    role: RoleName
    is_active: bool = True
    last_login_at: datetime | None = None


class CreateUserRequest(BaseRequestSchema):
    full_name: str = Field(..., min_length=2, max_length=100, description="Nom complet de l'utilisateur")
    role: RoleName = Field("CAISSIER", description="Rôle système de l'utilisateur")
    pin: str = Field(..., min_length=4, max_length=6, description="Code PIN numérique (4 à 6 chiffres)")


class UpdateUserRequest(BaseRequestSchema):
    full_name: str | None = Field(None, min_length=2, max_length=100, description="Nom complet mis à jour")
    role: RoleName | None = Field(None, description="Rôle système mis à jour")
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
