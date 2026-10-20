"""Ports vers l'extérieur (FNE, horloge). Implémentés dans `infrastructure/`, toujours
remplaçables par un mock. L'impression n'en est pas un : c'est l'agent du terminal qui vient
chercher les travaux (`services/printing_service.py`)."""

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol


class Clock(Protocol):
    def now(self) -> datetime: ...


@dataclass(frozen=True, slots=True)
class FneItemRef:
    """Article tel que certifié par la FNE : son `id` est requis pour un avoir."""

    id: str
    description: str
    quantity: int
    reference: str | None


@dataclass(frozen=True, slots=True)
class FneResult:
    external_number: str  # `reference` FNE, ex. 9606123E25000000019
    qr_payload: str  # `token` : URL de vérification à imprimer en QR
    invoice_id: str | None  # `invoice.id`, requis pour un avoir (absent des réponses d'avoir)
    items: tuple[FneItemRef, ...]
    amount_ttc: int | None
    vat_amount: int | None
    balance_funds_xof: int | None  # `balance_funds` : solde prépayé, remplace `balance_sticker`
    low_balance_warning: bool  # `warning` : seuil d'alerte fixé par la DGI
    raw: dict[str, Any]


class FneError(Exception):
    """Échec d'un appel FNE. Le type dit si un renvoi automatique est sans danger."""

    def __init__(self, message: str, *, status: int | None = None, body: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


class FneRejectedError(FneError):
    """4xx (hors 401) : données refusées, correction nécessaire. Rien n'a été certifié."""


class FneAuthError(FneError):
    """401 : clé API invalide. Rien n'a été certifié ; renvoi possible une fois la clé corrigée."""


class FneUnavailableError(FneError):
    """La requête n'a pas été traitée (connexion impossible, 502/503) : renvoi sans danger."""


class FneUncertainError(FneError):
    """La requête a pu être traitée (délai dépassé après envoi, 500, 504, réponse illisible) :
    **jamais** de renvoi automatique, l'API n'étant pas idempotente (PLAN-FNE D5)."""


class FneProvider(Protocol):
    def sign(self, payload: dict[str, Any], *, timeout: float) -> FneResult: ...

    def refund(self, invoice_id: str, payload: dict[str, Any], *, timeout: float) -> FneResult: ...
