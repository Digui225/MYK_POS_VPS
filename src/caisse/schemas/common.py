import uuid
from datetime import date

from pydantic import BaseModel, ConfigDict, Field

from caisse.domain.enums import UserRole


class Schema(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class Page[T](Schema):
    items: list[T] = Field(description="Éléments de la page")
    next_cursor: str | None = Field(
        default=None,
        description="Curseur de la page suivante (paramètre `cursor`) ; null : dernière page",
    )


class ApiWarning(Schema):
    code: str = Field(description="Code stable de l'avertissement")
    detail: str | None = Field(default=None, description="Texte indicatif (non affiché tel quel)")
    meta: dict[str, object] = Field(default={}, description="Données complémentaires")


class UserOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de l'utilisateur")
    full_name: str = Field(description="Nom complet", examples=["Awa Koné"])
    role: UserRole = Field(description="Rôle : ACHETEUR < CAISSIER < RESPONSABLE < ADMIN")


class OpenSessionOut(Schema):
    id: uuid.UUID = Field(description="Identifiant de la session de caisse")
    business_date: date = Field(description="Journée comptable de la session")
    cash_register_id: uuid.UUID = Field(description="Caisse sur laquelle la session est ouverte")
