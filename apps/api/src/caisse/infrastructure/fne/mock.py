"""FNE simulée (dév., démonstration, tests) : réponses au format de l'API réelle, sans réseau."""

import uuid
from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from caisse.domain.fne import FneError, FneRejectedError, FneResult
from caisse.infrastructure.fne.http_client import parse_result

_RATES = {"TVA": Decimal(18), "TVAB": Decimal(9), "TVAC": Decimal(0), "TVAD": Decimal(0)}


class MockFneProvider:
    def __init__(self, ncc: str = "9999999X", balance_sticker: int = 1000) -> None:
        self.ncc = ncc
        self.balance_sticker = balance_sticker
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.fail_next: list[FneError] = []  # erreurs à lever, dans l'ordre, avant tout traitement
        self._seq = 0
        self._invoices: dict[str, dict[str, Any]] = {}

    def sign(self, payload: dict[str, Any], *, timeout: float) -> FneResult:
        self.calls.append(("sign", payload))
        self._maybe_fail()
        items: list[dict[str, Any]] = []
        ht, ttc = Decimal(0), Decimal(0)
        for item in payload.get("items", []):
            rate = _RATES.get((item.get("taxes") or [""])[0])
            if rate is None:
                raise FneRejectedError("Invalid tax", status=400)
            line_ht = Decimal(str(item["amount"])) * item["quantity"]
            ht += line_ht
            ttc += line_ht * (1 + rate / 100)
            items.append({**item, "id": str(uuid.uuid4())})
        amount = int(ttc.quantize(Decimal(1), rounding=ROUND_HALF_UP))
        vat = amount - int(ht.quantize(Decimal(1), rounding=ROUND_HALF_UP))
        invoice_id = str(uuid.uuid4())
        invoice: dict[str, Any] = {
            "id": invoice_id,
            "type": "invoice",
            "amount": amount,
            "vatAmount": vat,
            "items": items,
        }
        self._invoices[invoice_id] = invoice
        return self._result(self._next_reference(""), invoice)

    def refund(self, invoice_id: str, payload: dict[str, Any], *, timeout: float) -> FneResult:
        self.calls.append(("refund", {"invoice_id": invoice_id, **payload}))
        self._maybe_fail()
        if invoice_id not in self._invoices:
            raise FneRejectedError("Invoice not found", status=400)
        return self._result(self._next_reference("A"), None)

    def _maybe_fail(self) -> None:
        if self.fail_next:
            raise self.fail_next.pop(0)

    def _next_reference(self, prefix: str) -> str:
        self._seq += 1
        return f"{prefix}{self.ncc}{datetime.now(UTC):%y}{self._seq:010d}"

    def _result(self, reference: str, invoice: dict[str, Any] | None) -> FneResult:
        self.balance_sticker -= 1
        token = f"mock://fne/verification/{uuid.uuid4()}"
        body: dict[str, Any] = {
            "ncc": self.ncc,
            "reference": reference,
            "token": token,
            "warning": self.balance_sticker < 10,
            "balance_sticker": self.balance_sticker,
        }
        if invoice is not None:
            body["invoice"] = {**invoice, "reference": reference}
        return parse_result(body)
