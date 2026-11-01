import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from caisse.core.config import Settings
from caisse.main import app


def test_security_headers_present_on_responses() -> None:
    """Vérifie que les en-têtes de sécurité HTTP sont injectés sur les réponses."""
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200

    headers = response.headers
    assert headers.get("X-Content-Type-Options") == "nosniff"
    assert headers.get("X-Frame-Options") == "DENY"
    assert headers.get("Referrer-Policy") == "strict-origin-when-cross-origin"
    assert headers.get("Permissions-Policy") == "geolocation=(), camera=(), microphone=()"


def test_production_settings_validation_rejects_debug() -> None:
    """Vérifie qu'un environnement de production refuse DEBUG=True."""
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            APP_ENV="production",
            DEBUG=True,
            JWT_SECRET="cle_tres_longue_et_securisee_pour_le_test_de_production_12345",
        )
    assert "DEBUG ne doit pas être actif" in str(exc_info.value)


def test_production_settings_validation_rejects_default_or_weak_jwt_secret() -> None:
    """Vérifie qu'un environnement de production refuse la clé secrète par défaut ou trop courte."""
    # Clé par défaut
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            APP_ENV="production",
            DEBUG=False,
            JWT_SECRET="default_secret_key_to_be_replaced_in_env_with_at_least_64_random_characters",
        )
    assert "JWT_SECRET doit être défini" in str(exc_info.value)

    # Clé trop courte (< 32 chars)
    with pytest.raises(ValidationError) as exc_info_short:
        Settings(
            APP_ENV="production",
            DEBUG=False,
            JWT_SECRET="trop_court_1234",
        )
    assert "JWT_SECRET doit être défini" in str(exc_info_short.value)


def test_production_settings_validation_accepts_valid_config() -> None:
    """Vérifie qu'une configuration de production valide est acceptée."""
    valid_settings = Settings(
        APP_ENV="production",
        DEBUG=False,
        JWT_SECRET="cle_tres_longue_et_securisee_pour_le_test_de_production_12345",
    )
    assert valid_settings.APP_ENV == "production"
    assert valid_settings.DEBUG is False
    assert valid_settings.docs_enabled is False


def test_trusted_host_blocks_invalid_host() -> None:
    """Vérifie que TrustedHostMiddleware bloque les en-têtes Host inconnus."""
    client = TestClient(app)
    response = client.get("/health", headers={"Host": "malicious-site.com"})
    assert response.status_code == 400
