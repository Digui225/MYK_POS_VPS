import logging
import pytest
from fastapi.testclient import TestClient

from caisse.main import app
from caisse.security_rate_limit import InMemoryRateLimiter, rate_limiter


def test_in_memory_rate_limiter_unit() -> None:
    """Vérifie le fonctionnement algorithmique du rate limiter in-memory."""
    limiter = InMemoryRateLimiter()
    key = "test-client-ip"

    # Autoriser 3 requêtes en 10 secondes
    allowed1, retry1 = limiter.check(key, max_requests=3, window_seconds=10)
    assert allowed1 is True
    assert retry1 == 0

    allowed2, retry2 = limiter.check(key, max_requests=3, window_seconds=10)
    assert allowed2 is True
    assert retry2 == 0

    allowed3, retry3 = limiter.check(key, max_requests=3, window_seconds=10)
    assert allowed3 is True
    assert retry3 == 0

    # La 4ème doit être rejetée
    allowed4, retry4 = limiter.check(key, max_requests=3, window_seconds=10)
    assert allowed4 is False
    assert retry4 > 0
    assert retry4 <= 10

    # Une autre clé ne doit pas être bloquée
    allowed_other, _ = limiter.check("another-client", max_requests=3, window_seconds=10)
    assert allowed_other is True

    # Réinitialisation
    limiter.reset()
    allowed_after_reset, _ = limiter.check(key, max_requests=3, window_seconds=10)
    assert allowed_after_reset is True


def test_auth_login_rate_limiting_triggers_429(
    client: TestClient, caplog: pytest.LogCaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Vérifie que l'endpoint /api/v1/auth/login déclenche un 429 après dépassement du quota."""
    from caisse.core.config import get_settings

    # Blocage après PIN erronés (test_login_lockout.py) écarté : seul le quota est testé ici
    monkeypatch.setattr(get_settings(), "PIN_MAX_FAILED_ATTEMPTS", 100)
    rate_limiter.reset()

    # Effectuer 10 tentatives rapides (quota par défaut)
    with caplog.at_level(logging.WARNING, logger="caisse.security"):
        for _ in range(10):
            res = client.post(
                "/api/v1/auth/login",
                json={"pin": "000000", "device_id": "test-device"},
            )
            # Les 10 premières sont des échecs d'identifiants (401)
            assert res.status_code == 401

        # La 11ème requête doit être rejetée par le rate limiter avec 429
        blocked_res = client.post(
            "/api/v1/auth/login",
            json={"pin": "000000", "device_id": "test-device"},
        )
        assert blocked_res.status_code == 429
        body = blocked_res.json()
        assert body["code"] == "RATE_LIMIT_EXCEEDED"
        assert "retry_after" in body["meta"]
        assert "Retry-After" in blocked_res.headers

    rate_limiter.reset()
