from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field

from caisse.schemas.common import BaseSchema

ExpenseCategory = Literal[
    "GAZ",
    "EMBALLAGE",
    "MARCHE_APPOINT",
    "REPARATION",
    "ENTRETIEN",
    "TRANSPORT",
    "SALAIRE",
    "AUTRE",
]


class CashExpenseCreate(BaseModel):
    business_date: date = Field(..., description="Date comptable d'imputation de la dépense")
    category: ExpenseCategory = Field(..., description="Catégorie de la dépense")
    amount_xof: int = Field(..., gt=0, description="Montant en FCFA (entier positif)")
    reason: str = Field(..., min_length=2, max_length=255, description="Motif ou désignation")
    recipient: str | None = Field(None, max_length=100, description="Bénéficiaire / Fournisseur payé")
    receipt_reference: str | None = Field(None, max_length=100, description="N° de reçu ou pièce justificative")
    deduct_from_cash_session: bool = Field(
        False, description="Si true et qu'une session de caisse est ouverte, déduit du tiroir-caisse"
    )


class CashExpenseOut(BaseSchema):
    id: str
    business_date: date
    cash_session_id: str | None
    user_id: str
    user_name: str
    category: str
    amount_xof: int
    recipient: str | None
    reason: str
    receipt_reference: str | None
    created_at: datetime


class CashExpenseListOut(BaseSchema):
    total_count: int
    total_amount_xof: int
    items: list[CashExpenseOut]


class BankDepositCreate(BaseModel):
    business_date: date = Field(..., description="Date comptable du versement")
    amount_xof: int = Field(..., gt=0, description="Montant versé en banque en FCFA")
    bank_name: str = Field(..., min_length=2, max_length=100, description="Nom de la banque (ex: BICICI, SIB)")
    slip_number: str = Field(..., min_length=2, max_length=100, description="N° de bordereau de versement")
    deposited_by: str | None = Field(None, max_length=100, description="Nom de la personne ayant déposé")
    notes: str | None = Field(None, max_length=255, description="Commentaire optionnel")


class BankDepositOut(BaseSchema):
    id: str
    business_date: date
    user_id: str
    user_name: str
    amount_xof: int
    bank_name: str
    slip_number: str
    deposited_by: str | None
    notes: str | None
    created_at: datetime


class BankDepositListOut(BaseSchema):
    total_count: int
    total_amount_xof: int
    items: list[BankDepositOut]
