"""Rôle SERVEUR et connexion des appareils de salle (lot 1 de l'écran serveur).

- l'écran « Qui prend le service ? » liste les serveurs actifs avant connexion ;
- connexion par compte choisi puis PIN : le blocage après PIN erronés porte sur le compte,
  jamais sur le poste (tous les téléphones sortent par la même adresse que la caisse) ;
- le serveur lit la carte, la salle et les commandes, mais n'encaisse ni n'annule rien.
"""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.core.security import hash_pin
from caisse.models.user import User

DEVICE = "telephone-salle-01"


@pytest.fixture
def serveurs(db_session: Session) -> dict[str, User]:
    koffi = User(full_name="Koffi", pin_hash=hash_pin("246810"), role="SERVEUR", is_active=True)
    awa = User(full_name="Awa", pin_hash=hash_pin("135791"), role="SERVEUR", is_active=True)
    parti = User(full_name="Ancien serveur", pin_hash=hash_pin("112244"), role="SERVEUR", is_active=False)
    db_session.add_all([koffi, awa, parti])
    db_session.commit()
    return {"koffi": koffi, "awa": awa, "parti": parti}


def _login_account(client: TestClient, user_id: str, pin: str):
    return client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": DEVICE, "user_id": user_id}
    )


def _headers(client: TestClient, user: User, pin: str) -> dict[str, str]:
    res = _login_account(client, user.id, pin)
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": DEVICE}


def test_staff_list_shows_only_active_waiters_without_login(
    client: TestClient, serveurs: dict[str, User]
) -> None:
    res = client.get("/api/v1/auth/staff")
    assert res.status_code == 200
    assert res.json() == [
        {"id": serveurs["awa"].id, "full_name": "Awa"},
        {"id": serveurs["koffi"].id, "full_name": "Koffi"},
    ]


def test_account_login_returns_the_waiter(client: TestClient, serveurs: dict[str, User]) -> None:
    res = _login_account(client, serveurs["koffi"].id, "246810")
    assert res.status_code == 200
    assert res.json()["user"]["role"] == "SERVEUR"
    assert res.json()["user"]["full_name"] == "Koffi"


def test_account_login_checks_only_that_account(client: TestClient, serveurs: dict[str, User]) -> None:
    # Le PIN de la caissière (123456) ne connecte pas sur le compte de Koffi
    res = _login_account(client, serveurs["koffi"].id, "123456")
    assert res.status_code == 401
    assert res.json()["code"] == "INVALID_CREDENTIALS"


def test_inactive_or_unknown_account_is_refused(client: TestClient, serveurs: dict[str, User]) -> None:
    assert _login_account(client, serveurs["parti"].id, "112244").status_code == 401
    assert _login_account(client, "compte-inexistant", "112244").status_code == 401


def test_wrong_pins_lock_the_account_not_the_restaurant(
    client: TestClient, serveurs: dict[str, User]
) -> None:
    koffi = serveurs["koffi"]
    for _ in range(get_settings().PIN_MAX_FAILED_ATTEMPTS):
        assert _login_account(client, koffi.id, "000000").status_code == 401

    locked = _login_account(client, koffi.id, "246810")  # PIN juste, compte bloqué
    assert locked.status_code == 429
    assert locked.json()["code"] == "PIN_LOCKOUT"
    assert 0 < locked.json()["meta"]["retry_after"] <= get_settings().LOCKOUT_DURATION_MINUTES * 60

    # Ni la caisse (PIN seul, même adresse) ni Awa ne sont bloquées
    caisse = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-terminal-01"})
    assert caisse.status_code == 200
    assert _login_account(client, serveurs["awa"].id, "135791").status_code == 200


def test_account_lock_expires_and_success_resets_the_count(
    client: TestClient, db_session: Session, serveurs: dict[str, User]
) -> None:
    koffi = serveurs["koffi"]
    koffi.locked_until = datetime.now(timezone.utc) - timedelta(seconds=1)
    koffi.failed_attempts = 3
    db_session.commit()

    assert _login_account(client, koffi.id, "246810").status_code == 200
    db_session.refresh(koffi)
    assert koffi.failed_attempts == 0
    assert koffi.locked_until is None


def test_account_login_has_its_own_quota(client: TestClient, serveurs: dict[str, User]) -> None:
    """Dix connexions d'un serveur n'épuisent pas le quota de la caisse ni des autres serveurs."""
    for _ in range(10):
        assert _login_account(client, serveurs["koffi"].id, "246810").status_code == 200
    blocked = _login_account(client, serveurs["koffi"].id, "246810")
    assert blocked.status_code == 429
    assert blocked.json()["code"] == "RATE_LIMIT_EXCEEDED"

    assert _login_account(client, serveurs["awa"].id, "135791").status_code == 200
    caisse = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-terminal-01"})
    assert caisse.status_code == 200


def test_waiter_reads_menu_floor_and_orders(client: TestClient, serveurs: dict[str, User]) -> None:
    headers = _headers(client, serveurs["koffi"], "246810")
    for path in (
        "/api/v1/categories",
        "/api/v1/products",
        "/api/v1/tables",
        "/api/v1/tables/board",
        "/api/v1/orders",
    ):
        res = client.get(path, headers=headers)
        assert res.status_code == 200, (path, res.text)


def test_waiter_cannot_cash_cancel_or_manage(client: TestClient, serveurs: dict[str, User]) -> None:
    headers = _headers(client, serveurs["koffi"], "246810")
    forbidden = [
        client.post(
            "/api/v1/cash-sessions",
            headers={**headers, "Idempotency-Key": "idem-serveur-session"},
            json={"cash_register_id": "caisse-01", "opening_float_xof": 50000},
        ),
        client.post(
            "/api/v1/orders/ord-x/payments",
            headers={**headers, "Idempotency-Key": "idem-serveur-paiement"},
            json={"method": "CASH", "amount_xof": 1000},
        ),
        client.post("/api/v1/orders/ord-x/cancel", headers=headers, json={"reason": "erreur"}),
        client.delete("/api/v1/orders/ord-x/items/item-x", headers=headers),
        client.get("/api/v1/users", headers=headers),
        client.post(
            "/api/v1/products",
            headers=headers,
            json={"name": "Plat inventé", "price_xof": 1000, "category_id": "cat-x"},
        ),
    ]
    for res in forbidden:
        assert res.status_code == 403, res.text
        assert res.json()["code"] == "INSUFFICIENT_PRIVILEGE"


def test_admin_creates_a_waiter_account(client: TestClient) -> None:
    login = client.post("/api/v1/auth/login", json={"pin": "999999", "device_id": "pos-terminal-01"})
    headers = {"Authorization": f"Bearer {login.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}
    res = client.post(
        "/api/v1/users", headers=headers, json={"full_name": "Moussa", "role": "SERVEUR", "pin": "864200"}
    )
    assert res.status_code == 201, res.text
    assert res.json()["role"] == "SERVEUR"
    assert [s["full_name"] for s in client.get("/api/v1/auth/staff").json()] == ["Moussa"]
