import pytest
from fastapi.testclient import TestClient

from caisse.core.config import get_settings
from caisse.security_rate_limit import login_lockout


def _login(client: TestClient, pin: str):
    return client.post("/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"})


def test_five_wrong_pins_lock_the_post(client: TestClient) -> None:
    for _ in range(5):
        assert _login(client, "000000").status_code == 401

    locked = _login(client, "123456")  # PIN juste, mais poste bloqué
    assert locked.status_code == 429
    assert locked.json()["code"] == "PIN_LOCKOUT"
    assert 0 < locked.json()["meta"]["retry_after"] <= get_settings().LOCKOUT_DURATION_MINUTES * 60


def test_a_right_pin_resets_the_count(client: TestClient) -> None:
    for _ in range(4):
        assert _login(client, "000000").status_code == 401
    assert _login(client, "123456").status_code == 200
    for _ in range(4):
        assert _login(client, "000000").status_code == 401
    assert _login(client, "123456").status_code == 200


def test_lock_expires(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    import caisse.core.security_rate_limit as module

    now = [1000.0]
    monkeypatch.setattr(module.time, "monotonic", lambda: now[0])
    for _ in range(5):
        _login(client, "000000")
    assert _login(client, "123456").status_code == 429

    now[0] += get_settings().LOCKOUT_DURATION_MINUTES * 60 + 1
    assert login_lockout.retry_after("testclient") == 0
    assert _login(client, "123456").status_code == 200
