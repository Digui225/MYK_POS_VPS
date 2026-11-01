"""Client HTTP FNE contre un transport simulé reprenant les exemples de la procédure DGI."""

import json
from collections.abc import Callable
from decimal import Decimal

import httpx
import pytest

from caisse.domain.fne import (
    FneAuthError,
    FneError,
    FneRejectedError,
    FneUnavailableError,
    FneUncertainError,
)
from caisse.infrastructure.fne import HttpFneProvider, MockFneProvider
from caisse.infrastructure.fne.http_client import dumps

BASE_URL = "http://fne.test/ws"

SIGN_RESPONSE = {
    "ncc": "9606123E",
    "reference": "9606123E25000000019",
    "token": "http://54.247.95.108/fr/verification/019465c1-3f61-766c-9652-706e32dfb436",
    "warning": False,
    "balance_sticker": 179,
    "invoice": {
        "id": "e2b2d8da-a532-4c08-9182-f5b428ca468d",
        "reference": "9606123E25000000019",
        "amount": 852660,
        "vatAmount": 172260,
        "items": [
            {
                "id": "bf9cc241-9b5f-4d26-a570-aa8e682a759e",
                "quantity": 30,
                "reference": "ref009",
                "description": "sac de riz Dinor 5 x 5",
            },
            {
                "id": "50b5c9d9-e22d-4dce-ba3c-5d2519c3418f",
                "quantity": 20,
                "reference": "ref001",
                "description": "Huile lesieur 5 litres",
            },
        ],
    },
}

REFUND_RESPONSE = {
    "ncc": "9606123E",
    "reference": "A9606123E2500000006",
    "token": "http://54.247.95.108/fr/verification/019465ca-c27c-700e-ba3f-09d0759b9170",
    "warning": False,
    "balance_sticker": 178,
}

VALIDATION_ERROR = {
    "message": "Bad Request Exception",
    "error": "bad_request",
    "statusCode": 400,
    "errors": {
        "items": {
            "isArray": "items must be an array",
        },
        "pointOfSale": {"isString": "pointOfSale must be a string"},
    },
}


def _provider(handler: Callable[[httpx.Request], httpx.Response]) -> HttpFneProvider:
    return HttpFneProvider(BASE_URL, "secret-key", transport=httpx.MockTransport(handler))


def test_sign_sends_bearer_json_and_parses_response() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=SIGN_RESPONSE)

    result = _provider(handler).sign({"items": [{"amount": Decimal("847.4576")}]}, timeout=4)

    request = seen[0]
    assert request.method == "POST"
    assert str(request.url) == f"{BASE_URL}/external/invoices/sign"
    assert request.headers["authorization"] == "Bearer secret-key"
    assert request.headers["accept"] == "application/json"
    assert json.loads(request.content) == {"items": [{"amount": 847.4576}]}
    assert result.external_number == "9606123E25000000019"
    assert result.qr_payload.endswith("706e32dfb436")
    assert result.invoice_id == "e2b2d8da-a532-4c08-9182-f5b428ca468d"
    assert [i.reference for i in result.items] == ["ref009", "ref001"]
    assert (result.amount_ttc, result.vat_amount) == (852660, 172260)
    assert (result.balance_sticker, result.sticker_warning) == (179, False)


def test_refund_targets_invoice_and_parses_short_response() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/ws/external/invoices/inv-1/refund"
        return httpx.Response(201, json=REFUND_RESPONSE)

    result = _provider(handler).refund("inv-1", {"items": [{"id": "x", "quantity": 1}]}, timeout=4)
    assert result.external_number == "A9606123E2500000006"
    assert result.invoice_id is None
    assert result.items == ()


def test_validation_error_keeps_field_details() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json=VALIDATION_ERROR)

    with pytest.raises(FneRejectedError) as exc:
        _provider(handler).sign({}, timeout=4)
    assert "pointOfSale" in exc.value.body["errors"]


@pytest.mark.parametrize(
    ("status", "body", "error"),
    [
        (400, {"message": "Point of sale is not valid", "error": "bad_request"}, FneRejectedError),
        (401, {"message": "Invalid API Key", "error": "unauthorized"}, FneAuthError),
        (404, {"message": "Not found"}, FneRejectedError),
        (
            500,
            {"message": "Error signing invoice", "error": "invoice_signing_error"},
            FneUncertainError,
        ),
        (502, "bad gateway", FneUnavailableError),
        (503, "maintenance", FneUnavailableError),
        (504, "gateway timeout", FneUncertainError),
        (200, {"message": "ok"}, FneUncertainError),
    ],
)
def test_status_classification(status: int, body: object, error: type[FneError]) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if isinstance(body, dict):
            return httpx.Response(status, json=body)
        return httpx.Response(status, text=str(body))

    with pytest.raises(error) as exc:
        _provider(handler).sign({}, timeout=4)
    assert exc.value.status == status


@pytest.mark.parametrize(
    ("raised", "error"),
    [
        (httpx.ConnectError("refused"), FneUnavailableError),
        (httpx.ConnectTimeout("slow"), FneUnavailableError),
        (httpx.ReadTimeout("slow"), FneUncertainError),
        (httpx.RemoteProtocolError("cut"), FneUncertainError),
    ],
)
def test_transport_errors(raised: Exception, error: type[FneError]) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise raised

    with pytest.raises(error):
        _provider(handler).sign({}, timeout=4)


def test_requires_url_and_key() -> None:
    with pytest.raises(ValueError):
        HttpFneProvider("", "key")
    with pytest.raises(ValueError):
        HttpFneProvider(BASE_URL, "")


def test_dumps_keeps_integers_and_decimals() -> None:
    assert dumps({"a": Decimal("1000"), "b": Decimal("847.4576"), "c": "é"}) == (
        '{"a": 1000, "b": 847.4576, "c": "é"}'.encode()
    )


def test_mock_provider_round_trip() -> None:
    mock = MockFneProvider(ncc="1234567A")
    sale = mock.sign(
        {
            "items": [
                {
                    "taxes": ["TVA"],
                    "quantity": 2,
                    "amount": Decimal("2966.1017"),
                    "description": "Poisson",
                }
            ]
        },
        timeout=4,
    )
    assert sale.external_number.startswith("1234567A")
    assert sale.amount_ttc == 7000
    assert sale.invoice_id is not None and len(sale.items) == 1
    credit = mock.refund(
        sale.invoice_id, {"items": [{"id": sale.items[0].id, "quantity": 1}]}, timeout=4
    )
    assert credit.external_number.startswith("A1234567A")
    mock.fail_next.append(FneUncertainError("timeout"))
    with pytest.raises(FneUncertainError):
        mock.sign({"items": []}, timeout=4)
    with pytest.raises(FneRejectedError):
        mock.refund("unknown", {"items": []}, timeout=4)
