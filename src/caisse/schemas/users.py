import uuid
from datetime import datetime

from pydantic import ConfigDict, Field

from caisse.domain.enums import UserRole
from caisse.schemas.common import Schema

_PIN_DESCRIPTION = "Code PIN à 6 chiffres, unique parmi les utilisateurs actifs"


class UserDetail(Schema):
    id: uuid.UUID = Field(description="Identifiant de l'utilisateur")
    full_name: str = Field(description="Nom complet", examples=["Awa Koné"])
    role: UserRole = Field(description="Rôle : ACHETEUR < CAISSIER < RESPONSABLE < ADMIN")
    is_active: bool = Field(description="Faux : connexion impossible et jetons refusés")
    last_login_at: datetime | None = Field(description="Dernière connexion réussie")
    created_at: datetime = Field(description="Date de création")


class UserCreate(Schema):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [{"full_name": "Awa Koné", "role": "CAISSIER", "pin": "111111"}]
        }
    )

    full_name: str = Field(min_length=1, max_length=120, description="Nom complet")
    role: UserRole = Field(description="Rôle : ACHETEUR < CAISSIER < RESPONSABLE < ADMIN")
    pin: str = Field(pattern=r"^\d{4,8}$", description=_PIN_DESCRIPTION)


class UserUpdate(Schema):
    model_config = ConfigDict(json_schema_extra={"examples": [{"is_active": False}]})

    full_name: str | None = Field(
        default=None, min_length=1, max_length=120, description="Nouveau nom complet"
    )
    role: UserRole | None = Field(default=None, description="Nouveau rôle, effectif immédiatement")
    is_active: bool | None = Field(
        default=None, description="Faux : désactive le compte et coupe ses jetons immédiatement"
    )


class PinUpdate(Schema):
    model_config = ConfigDict(json_schema_extra={"examples": [{"pin": "222222"}]})

    pin: str = Field(pattern=r"^\d{4,8}$", description=_PIN_DESCRIPTION)
