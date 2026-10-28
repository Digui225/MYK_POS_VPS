"""Client HTTP de l'API FNE (DGI). Traduit chaque issue réseau en une erreur typée qui dit si
un renvoi automatique est sans danger (voir `caisse.domain.ports`)."""

import json
import logging
import time
from decimal import Decimal
from typing import Any

import httpx

from caisse.domain.ports import (
    FneAuthError,
    FneItemRef,
    FneRejectedError,
    FneResult,
    FneUnavailableError,
    FneUncertainError,
)

logger = logging.getLogger(__name__)

# Statuts où la requête n'a pas été traitée par la FNE. 500 n'en fait pas partie : constaté le
# 01/10/2026, un 500 `invoice_signing_error` (stock de stickers vide) laisse une facture créée,
# non signée, dans l'espace FNE. 504 non plus : la passerelle a abandonné, la FNE a pu certifier.
_NOT_PROCESSED_STATUSES = {502, 503}


def _json_default(value: object) -> object:
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"{type(value).__name__} non sérialisable en JSON")


def dumps(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, default=_json_default, ensure_ascii=False).encode()


def _int_or_none(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return round(value)


def parse_result(data: Any) -> FneResult:
    """Réponse 200/201 de `sign` ou `refund`. Sans `reference` ni `token`, on ne sait pas ce qui a
    été certifié : résultat incertain."""
    if not isinstance(data, dict):
        raise FneUncertainError("réponse FNE illisible", body=data)
    reference, token = data.get("reference"), data.get("token")
    if not isinstance(reference, str) or not reference or not isinstance(token, str) or not token:
        raise FneUncertainError("réponse FNE sans référence ni token", body=data)
    raw_invoice = data.get("invoice")
    invoice: dict[str, Any] = raw_invoice if isinstance(raw_invoice, dict) else {}
    items = tuple(
        FneItemRef(
            id=str(item["id"]),
            description=str(item.get("description") or ""),
            quantity=_int_or_none(item.get("quantity")) or 0,
            reference=item.get("reference"),
        )
        for item in invoice.get("items") or []
        if isinstance(item, dict) and item.get("id")
    )
    invoice_id = invoice.get("id")
    return FneResult(
        external_number=reference,
        qr_payload=token,
        invoice_id=str(invoice_id) if invoice_id else None,
        items=items,
        amount_ttc=_int_or_none(invoice.get("amount")),
        vat_amount=_int_or_none(invoice.get("vatAmount")),
        balance_sticker=_int_or_none(data.get("balance_sticker")),
        sticker_warning=bool(data.get("warning")),
        raw=data,
    )


class HttpFneProvider:
    def __init__(
        self, base_url: str, api_key: str, *, transport: httpx.BaseTransport | None = None
    ) -> None:
        if not base_url or not api_key:
            raise ValueError("FNE_API_BASE_URL et FNE_API_KEY sont obligatoires en mode api")
        self._client = httpx.Client(
            base_url=base_url.rstrip("/"),
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            transport=transport,
        )

    def sign(self, payload: dict[str, Any], *, timeout: float) -> FneResult:
        return self._post("/external/invoices/sign", payload, timeout)

    def refund(self, invoice_id: str, payload: dict[str, Any], *, timeout: float) -> FneResult:
        return self._post(f"/external/invoices/{invoice_id}/refund", payload, timeout)

    def _post(self, path: str, payload: dict[str, Any], timeout: float) -> FneResult:
        started = time.monotonic()
        try:
            response = self._client.post(
                path,
                content=dumps(payload),
                timeout=httpx.Timeout(timeout, connect=min(timeout, 3.0)),
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as exc:
            # la requête n'est jamais partie
            raise FneUnavailableError(f"FNE injoignable : {exc!r}") from exc
        except (httpx.ProxyError, httpx.UnsupportedProtocol) as exc:
            raise FneUnavailableError(f"FNE injoignable : {exc!r}") from exc
        except httpx.TransportError as exc:
            # délai de lecture/écriture dépassé, connexion coupée : envoyée, issue inconnue
            raise FneUncertainError(f"issue inconnue : {exc!r}") from exc
        elapsed_ms = round((time.monotonic() - started) * 1000)
        logger.info("fne_call path=%s status=%s elapsed_ms=%s", path, response.status_code, elapsed_ms)
        return self._handle(response)

    @staticmethod
    def _handle(response: httpx.Response) -> FneResult:
        status = response.status_code
        try:
            body: Any = response.json()
        except ValueError:
            body = response.text[:500]
        message = body.get("message") if isinstance(body, dict) else None
        error_details: list[str] = []
        if isinstance(body, dict):
            errors = body.get("errors")
            if isinstance(errors, dict):
                for field, field_err in errors.items():
                    if isinstance(field_err, dict):
                        error_details.append(f"{field}: {', '.join(str(v) for v in field_err.values())}")
                    elif isinstance(field_err, list):
                        error_details.append(f"{field}: {', '.join(str(e) for e in field_err)}")
                    else:
                        error_details.append(f"{field}: {field_err}")
            elif isinstance(errors, list):
                error_details.append(", ".join(str(e) for e in errors))

        if error_details:
            detail = f"FNE {status} : {message or 'Erreur'} ({'; '.join(error_details)})"
        else:
            detail = f"FNE {status} : {message or body}"
        if 200 <= status < 300:
            try:
                return parse_result(body)
            except FneUncertainError as exc:
                exc.status = status
                raise
        if status == 401:
            raise FneAuthError(detail, status=status, body=body)
        if status in _NOT_PROCESSED_STATUSES:
            raise FneUnavailableError(detail, status=status, body=body)
        if 400 <= status < 500:
            raise FneRejectedError(detail, status=status, body=body)
        raise FneUncertainError(detail, status=status, body=body)
