"""Exceptions métier → application/problem+json (RFC 9457). Voir 03-CONTRAT-API.md §2."""

import re
from typing import Any

import structlog
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = structlog.get_logger()

PROBLEM_JSON = "application/problem+json"
ERROR_TYPE_BASE = "https://caisse.local/errors/"


class DomainError(Exception):
    """Erreur métier → 4xx avec un `code` contractuel stable."""

    status: int = 400
    code: str = "DOMAIN_ERROR"
    title: str = "Erreur métier"

    def __init__(self, detail: str | None = None, meta: dict[str, Any] | None = None) -> None:
        super().__init__(detail or self.title)
        self.detail = detail or self.title
        self.meta = meta or {}
        self.headers: dict[str, str] = {}


class InfrastructureError(Exception):
    """Panne technique → 5xx, message générique, log complet."""

    status: int = 503
    code: str = "INFRASTRUCTURE_ERROR"


def _error(name: str, status: int, title: str, code: str | None = None) -> type[DomainError]:
    attrs = {"status": status, "code": code or _snake_upper(name), "title": title}
    return type(name, (DomainError,), attrs)


def _snake_upper(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name.removesuffix("Error")).upper()


# Catalogue MVP (03-CONTRAT-API.md §2)
InvalidCredentialsError = _error("InvalidCredentialsError", 401, "Code PIN invalide")
AccountLockedError = _error("AccountLockedError", 423, "Trop d'essais, poste temporairement bloqué")
TokenExpiredError = _error("TokenExpiredError", 401, "Jeton expiré ou invalide")
InsufficientPrivilegeError = _error("InsufficientPrivilegeError", 403, "Rôle insuffisant")
OverrideRequiredError = _error("OverrideRequiredError", 403, "Autorisation responsable requise")
NoOpenSessionError = _error("NoOpenSessionError", 409, "Aucune session de caisse ouverte")
SessionAlreadyOpenError = _error("SessionAlreadyOpenError", 409, "Une session est déjà ouverte")
SessionAlreadyClosedError = _error("SessionAlreadyClosedError", 409, "Session déjà clôturée")
SessionNotClosedError = _error(
    "SessionNotClosedError", 409, "Rapport Z indisponible avant la clôture"
)
SessionHasOpenOrdersError = _error("SessionHasOpenOrdersError", 409, "Commandes non soldées")
BusinessDateMismatchError = _error(
    "BusinessDateMismatchError", 409, "Journée comptable à confirmer"
)
TableAlreadyOccupiedError = _error("TableAlreadyOccupiedError", 409, "Table déjà occupée")
OrderLabelTakenError = _error(
    "OrderLabelTakenError", 409, "Une commande active de la table porte déjà cette étiquette"
)
TableLabelExistsError = _error("TableLabelExistsError", 409, "Une table porte déjà ce libellé")
CashRegisterNameExistsError = _error(
    "CashRegisterNameExistsError", 409, "Une caisse porte déjà ce nom"
)
CashRegisterHasOpenSessionError = _error(
    "CashRegisterHasOpenSessionError", 409, "Une session est ouverte sur cette caisse"
)
TableHasActiveOrdersError = _error(
    "TableHasActiveOrdersError", 409, "La table a des commandes en cours"
)
OrderNotEditableError = _error("OrderNotEditableError", 409, "Commande non modifiable")
PaymentExceedsDueError = _error("PaymentExceedsDueError", 422, "Montant supérieur au reste dû")
PaymentNotVoidableError = _error("PaymentNotVoidableError", 409, "Paiement impossible à annuler")
PaymentMethodDisabledError = _error(
    "PaymentMethodDisabledError", 422, "Moyen de paiement non proposé par la caisse"
)
IdempotencyConflictError = _error("IdempotencyConflictError", 409, "Clé d'idempotence réutilisée")
NotFoundError = _error("NotFoundError", 404, "Ressource introuvable")
PinAlreadyUsedError = _error("PinAlreadyUsedError", 409, "Ce code PIN est déjà attribué")
ValidationError = _error("ValidationError", 422, "Données invalides", "VALIDATION_ERROR")
CustomerNccExistsError = _error("CustomerNccExistsError", 409, "NCC déjà enregistré")
FneOrderNotPaidError = _error("FneOrderNotPaidError", 409, "Commande non soldée")
FneNotConfiguredError = _error(
    "FneNotConfiguredError", 409, "Point de vente ou établissement FNE non paramétré"
)
FneDocumentStateError = _error(
    "FneDocumentStateError", 409, "Document FNE dans un état qui interdit cette action"
)
FneRefundExceedsError = _error(
    "FneRefundExceedsError", 422, "Quantité d'avoir supérieure à la quantité certifiée"
)
NoReceiptToReprintError = _error(
    "NoReceiptToReprintError", 409, "Aucun ticket à ré-imprimer pour cette commande"
)
PrintJobNotRetryableError = _error(
    "PrintJobNotRetryableError", 409, "Travail d'impression dans un état qui interdit le renvoi"
)
PrintJobNotClaimedError = _error(
    "PrintJobNotClaimedError", 409, "Travail d'impression non pris par ce terminal"
)
PrintTerminalNameExistsError = _error(
    "PrintTerminalNameExistsError", 409, "Un terminal d'impression porte déjà ce nom"
)
TerminalTokenInvalidError = _error(
    "TerminalTokenInvalidError", 401, "Jeton de terminal invalide ou révoqué"
)
StockArticleNameExistsError = _error(
    "StockArticleNameExistsError", 409, "Un article de stock porte déjà ce nom"
)
CategoryNameExistsError = _error("CategoryNameExistsError", 409, "Une catégorie porte déjà ce nom")
CategoryNotEmptyError = _error(
    "CategoryNotEmptyError", 409, "La catégorie contient encore des produits actifs"
)
ProductNameExistsError = _error(
    "ProductNameExistsError", 409, "Un produit du menu porte déjà ce nom"
)
ProductSkuExistsError = _error("ProductSkuExistsError", 409, "Ce code article est déjà utilisé")


class RateLimitExceededError(DomainError):
    """Trop de requêtes depuis une même adresse IP ; `Retry-After` donne l'attente."""

    status = 429
    code = "RATE_LIMIT_EXCEEDED"
    title = "Trop de requêtes, réessayer plus tard"

    def __init__(self, retry_after: int, *, limit: int, window_seconds: int) -> None:
        super().__init__(
            f"Réessayer dans {retry_after} s.",
            meta={"retry_after": retry_after, "limit": limit, "window_seconds": window_seconds},
        )
        self.headers = {"Retry-After": str(retry_after)}


class PrinterUnavailableError(InfrastructureError):
    """L'agent d'impression se signale, mais rapporte une imprimante hors ligne — réservé aux
    actions directes (`/printing/*`)."""

    code = "PRINTER_UNAVAILABLE"


class PrintAgentUnavailableError(InfrastructureError):
    """Aucun agent ne s'est signalé récemment — réservé aux actions directes (`/printing/*`) :
    une ouverture de tiroir ou un test mis en file ne doivent pas partir des minutes plus tard."""

    code = "PRINT_AGENT_UNAVAILABLE"


class FneInvalidDataError(DomainError):
    """Commande impossible à traduire en FNE ; `code` précis venant du domaine
    (`FNE_NCC_REQUIRED`, `FNE_VAT_RATE_UNMAPPED`, `FNE_NO_PAYMENT`…)."""

    status = 422
    title = "Données insuffisantes pour la FNE"

    def __init__(self, code: str, detail: str, meta: dict[str, Any] | None = None) -> None:
        super().__init__(detail, meta)
        self.code = code


def _problem(
    request: Request,
    *,
    status: int,
    code: str,
    title: str,
    detail: str,
    meta: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    body = {
        "type": ERROR_TYPE_BASE + code.lower().replace("_", "-"),
        "title": title,
        "status": status,
        "code": code,
        "detail": detail,
        "meta": meta or {},
        "request_id": getattr(request.state, "request_id", None),
    }
    return JSONResponse(body, status_code=status, media_type=PROBLEM_JSON, headers=headers)


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def _domain(request: Request, exc: DomainError) -> JSONResponse:
        return _problem(
            request,
            status=exc.status,
            code=exc.code,
            title=exc.title,
            detail=exc.detail,
            meta=exc.meta,
            headers=exc.headers or None,
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        fields = [{"loc": list(e["loc"]), "type": e["type"], "msg": e["msg"]} for e in exc.errors()]
        return _problem(
            request,
            status=422,
            code="VALIDATION_ERROR",
            title="Données invalides",
            detail="Requête invalide",
            meta={"fields": fields},
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = "NOT_FOUND" if exc.status_code == 404 else f"HTTP_{exc.status_code}"
        return _problem(
            request,
            status=exc.status_code,
            code=code,
            title=str(exc.detail),
            detail=str(exc.detail),
        )

    @app.exception_handler(InfrastructureError)
    async def _infra(request: Request, exc: InfrastructureError) -> JSONResponse:
        log.error("infrastructure_error", code=exc.code, error=str(exc))
        return _problem(
            request,
            status=exc.status,
            code=exc.code,
            title="Service momentanément indisponible",
            detail="Réessayez",
        )

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        # Aucune stack trace ne sort de l'API : elle va dans les logs uniquement.
        log.exception("unhandled_error")
        return _problem(
            request,
            status=500,
            code="INTERNAL_ERROR",
            title="Erreur interne",
            detail="Erreur interne",
        )
