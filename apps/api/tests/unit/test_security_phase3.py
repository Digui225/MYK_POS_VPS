import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from caisse.config import get_settings
from caisse.main import app
from caisse.schemas.auth import CreateUserRequest, LoginRequest


def test_schema_extra_forbid_unit() -> None:
    """Vérifie que les schémas sensibles refusent les champs inattendus (anti-mass-assignment)."""
    # LoginRequest valide
    req = LoginRequest(pin="123456", device_id="pos-01")
    assert req.pin == "123456"

    # Tentative d'injection d'un champ non prévu
    with pytest.raises(ValidationError) as exc_info:
        LoginRequest(pin="123456", device_id="pos-01", is_admin=True)  # type: ignore
    assert "extra_forbidden" in str(exc_info.value) or "Extra inputs are not permitted" in str(exc_info.value)

    # CreateUserRequest avec injection
    with pytest.raises(ValidationError) as exc_user:
        CreateUserRequest(full_name="Attaquant", role="ADMIN", pin="123456", is_superuser=True)  # type: ignore
    assert "extra_forbidden" in str(exc_user.value) or "Extra inputs are not permitted" in str(exc_user.value)


def test_api_rejects_extra_fields_in_payload(client: TestClient) -> None:
    """Vérifie que l'API renvoie 422 VALIDATION_ERROR si un champ inattendu est injecté."""
    res = client.post(
        "/api/v1/auth/login",
        json={
            "pin": "123456",
            "device_id": "pos-terminal-01",
            "malicious_extra_field": "hacked",
        },
    )
    assert res.status_code == 422
    body = res.json()
    assert body["code"] == "VALIDATION_ERROR"
    assert any("malicious_extra_field" in str(field) for field in body["meta"].get("fields", []))


def test_request_size_limit_middleware_rejects_oversized_payload() -> None:
    """Vérifie que le middleware rejette les corps de requête dépassant MAX_REQUEST_BODY_SIZE."""
    client = TestClient(app)
    settings = get_settings()

    # Simuler une requête avec un Content-Length supérieur à la limite
    oversized_length = settings.MAX_REQUEST_BODY_SIZE + 1024
    res = client.post(
        "/api/v1/auth/login",
        content=b"{}",
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(oversized_length),
        },
    )
    assert res.status_code == 413
    body = res.json()
    assert body["code"] == "PAYLOAD_TOO_LARGE"
    assert body["meta"]["max_bytes"] == settings.MAX_REQUEST_BODY_SIZE
