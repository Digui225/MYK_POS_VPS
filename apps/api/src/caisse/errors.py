import uuid
from typing import Any
from fastapi import Request, status
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError


class CaisseException(Exception):
    def __init__(
        self,
        code: str,
        title: str,
        detail: str,
        status_code: int = status.HTTP_400_BAD_REQUEST,
        meta: dict[str, Any] | None = None,
    ):
        self.code = code
        self.title = title
        self.detail = detail
        self.status_code = status_code
        self.meta = meta or {}
        super().__init__(detail)


class ValidationError(CaisseException):
    def __init__(self, detail: str = "Erreur de validation", meta: dict[str, Any] | None = None):
        super().__init__(
            code="VALIDATION_ERROR",
            title="Données invalides",
            detail=detail,
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            meta=meta or {},
        )


class NotFoundError(CaisseException):
    def __init__(self, detail: str = "Ressource introuvable", meta: dict[str, Any] | None = None):
        super().__init__(
            code="NOT_FOUND",
            title="Ressource introuvable",
            detail=detail,
            status_code=status.HTTP_404_NOT_FOUND,
            meta=meta or {},
        )


class StockArticleNameExistsError(CaisseException):
    def __init__(self, detail: str = "Un article porte déjà ce nom", meta: dict[str, Any] | None = None):
        super().__init__(
            code="STOCK_ARTICLE_NAME_EXISTS",
            title="Nom d'article déjà utilisé",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


class IdempotencyConflictError(CaisseException):
    def __init__(self, detail: str = "Clé d'idempotence réutilisée avec un corps différent", meta: dict[str, Any] | None = None):
        super().__init__(
            code="IDEMPOTENCY_CONFLICT",
            title="Conflit d'idempotence",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


# Exceptions métier FNE & Clients
class CustomerNccExistsError(CaisseException):
    def __init__(self, detail: str = "NCC déjà enregistré", meta: dict[str, Any] | None = None):
        super().__init__(
            code="CUSTOMER_NCC_EXISTS",
            title="NCC déjà enregistré",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


class FneOrderNotPaidError(CaisseException):
    def __init__(self, detail: str = "Commande non soldée", meta: dict[str, Any] | None = None):
        super().__init__(
            code="FNE_ORDER_NOT_PAID",
            title="Commande non soldée",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


class FneNotConfiguredError(CaisseException):
    def __init__(self, detail: str = "Point de vente ou établissement FNE non paramétré", meta: dict[str, Any] | None = None):
        super().__init__(
            code="FNE_NOT_CONFIGURED",
            title="FNE non configurée",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


class FneDocumentStateError(CaisseException):
    def __init__(self, detail: str = "Document FNE dans un état qui interdit cette action", meta: dict[str, Any] | None = None):
        super().__init__(
            code="FNE_DOCUMENT_STATE",
            title="État du document incompatible",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )


class FneRefundExceedsError(CaisseException):
    def __init__(self, detail: str = "Quantité d'avoir supérieure à la quantité certifiée", meta: dict[str, Any] | None = None):
        super().__init__(
            code="FNE_REFUND_EXCEEDS",
            title="Quantité d'avoir excessive",
            detail=detail,
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            meta=meta or {},
        )


class FneInvalidDataError(CaisseException):
    def __init__(self, code: str, detail: str, meta: dict[str, Any] | None = None):
        super().__init__(
            code=code,
            title="Données insuffisantes pour la FNE",
            detail=detail,
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            meta=meta or {},
        )


class PurchaseStateError(CaisseException):
    def __init__(
        self,
        detail: str = "Action impossible dans l'état actuel de la demande d'achat",
        meta: dict[str, Any] | None = None,
    ):
        super().__init__(
            code="PURCHASE_STATE",
            title="État de la demande incompatible",
            detail=detail,
            status_code=status.HTTP_409_CONFLICT,
            meta=meta or {},
        )



def problem_json_response(
    status_code: int,
    code: str,
    title: str,
    detail: str,
    request_id: str | None = None,
    meta: dict[str, Any] | None = None,
) -> JSONResponse:
    type_slug = code.lower().replace("_", "-")
    content = {
        "type": f"https://caisse.local/errors/{type_slug}",
        "title": title,
        "status": status_code,
        "code": code,
        "detail": detail,
        "meta": meta or {},
        "request_id": request_id or str(uuid.uuid4()),
    }
    return JSONResponse(
        status_code=status_code,
        content=content,
        media_type="application/problem+json",
    )


async def caisse_exception_handler(request: Request, exc: CaisseException) -> JSONResponse:
    request_id = getattr(request.state, "request_id", str(uuid.uuid4()))
    response = problem_json_response(
        status_code=exc.status_code,
        code=exc.code,
        title=exc.title,
        detail=exc.detail,
        request_id=request_id,
        meta=exc.meta,
    )
    if exc.code == "RATE_LIMIT_EXCEEDED" and "retry_after" in exc.meta:
        response.headers["Retry-After"] = str(exc.meta["retry_after"])
    return response


async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    request_id = getattr(request.state, "request_id", str(uuid.uuid4()))
    fields_errors = []
    for err in exc.errors():
        loc = ".".join(str(item) for item in err.get("loc", []))
        fields_errors.append(
            {
                "field": loc,
                "message": err.get("msg", "Invalid value"),
                "type": err.get("type", "value_error"),
            }
        )

    return problem_json_response(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        code="VALIDATION_ERROR",
        title="Données de requête invalides",
        detail="Une ou plusieurs erreurs de validation ont été détectées.",
        request_id=request_id,
        meta={"fields": fields_errors},
    )


async def unhandled_exception_handler(
    request: Request, exc: Exception
) -> JSONResponse:
    request_id = getattr(request.state, "request_id", str(uuid.uuid4()))
    return problem_json_response(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        code="INTERNAL_SERVER_ERROR",
        title="Erreur interne du serveur",
        detail=str(exc) or "Une erreur inattendue est survenue.",
        request_id=request_id,
        meta={},
    )
