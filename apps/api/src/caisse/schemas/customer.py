import re
from datetime import datetime
from typing import Any, Optional

from pydantic import Field, field_validator, model_validator

from caisse.schemas.common import BaseSchema

# Format officiel DGI CI (ex. 9506466A, 1304777N) : 7 chiffres + 1 lettre majuscule
NCC_PATTERN = r"^\d{7}[A-Z]$"


class CustomerBase(BaseSchema):
    company_name: str = Field(..., min_length=1, max_length=200, json_schema_extra={"example": "ENTREPRISE IVOIRIENNE SARL"})
    ncc: Optional[str] = Field(
        None,
        max_length=50,
        pattern=NCC_PATTERN,
        description="N° de compte contribuable : 7 chiffres + 1 lettre",
        json_schema_extra={"example": "9506466A"},
    )
    phone: Optional[str] = Field(None, max_length=50, json_schema_extra={"example": "+2250701020304"})
    email: Optional[str] = Field(None, max_length=160, json_schema_extra={"example": "contact@entreprise.ci"})
    tax_regime: Optional[str] = Field(None, max_length=50, json_schema_extra={"example": "Régime TEE"})
    address: Optional[str] = Field(None, max_length=255, json_schema_extra={"example": "Abidjan Cocody"})

    @field_validator("ncc", mode="before")
    @classmethod
    def _normalize_ncc(cls, value: object) -> object:
        if isinstance(value, str):
            value = value.replace(" ", "").upper()
            return value or None
        return value

    @field_validator("company_name", mode="before")
    @classmethod
    def _strip(cls, value: object) -> object:
        return value.strip() if isinstance(value, str) else value


class CustomerCreate(BaseSchema):
    company_name: Optional[str] = None
    name: Optional[str] = None
    ncc: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_regime: Optional[str] = None
    address: Optional[str] = None

    @model_validator(mode="before")
    @classmethod
    def _unify_name(cls, data: Any) -> Any:
        if isinstance(data, dict):
            name = data.get("company_name") or data.get("name")
            if not name:
                raise ValueError("Raison sociale obligatoire (company_name ou name)")
            data["company_name"] = str(name).strip()
            data["name"] = data["company_name"]
            if data.get("ncc"):
                ncc = str(data["ncc"]).replace(" ", "").upper()
                if not re.match(NCC_PATTERN, ncc):
                    raise ValueError(f"Format NCC invalide : {ncc} (7 chiffres + 1 lettre attendu)")
                data["ncc"] = ncc
        return data


class CustomerUpdate(BaseSchema):
    company_name: Optional[str] = None
    name: Optional[str] = None
    ncc: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_regime: Optional[str] = None
    address: Optional[str] = None
    is_active: Optional[bool] = None


class CustomerOut(BaseSchema):
    id: str
    company_name: str
    name: Optional[str] = None
    ncc: Optional[str] = None
    tax_regime: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    address: Optional[str] = None
    is_active: bool = True
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    @model_validator(mode="before")
    @classmethod
    def _fill_alias(cls, data: Any) -> Any:
        if hasattr(data, "name") and not getattr(data, "company_name", None):
            setattr(data, "company_name", data.name)
        return data


# Alias pour rétro-compatibilité
CustomerResponse = CustomerOut
