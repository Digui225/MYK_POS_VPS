import asyncio
import threading

import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from caisse.core.config import get_settings
from caisse.infrastructure.websocket.manager import WebSocketManager
from caisse.main import app
from caisse.security import create_access_token, create_override_token, create_refresh_token


class DummyWS:
    def __init__(self):
        self.accepted = False
        self.sent = []

    async def accept(self):
        self.accepted = True

    async def send_json(self, data):
        self.sent.append(data)


def test_websocket_manager_lifecycle():
    async def _test():
        manager = WebSocketManager()
        assert len(manager.active_connections) == 0

        dummy = DummyWS()
        await manager.connect(dummy, authenticated=True)  # type: ignore
        assert dummy.accepted is True
        assert len(manager.active_connections) == 1

        await manager.broadcast("ORDER_PAID", {"order_id": "123"})
        assert len(dummy.sent) == 1
        assert dummy.sent[0]["type"] == "ORDER_PAID"
        assert dummy.sent[0]["data"]["order_id"] == "123"

        manager.disconnect(dummy)  # type: ignore
        assert len(manager.active_connections) == 0

    asyncio.run(_test())


def test_anonymous_client_receives_event_type_only():
    async def _test():
        manager = WebSocketManager()
        anonymous, authenticated = DummyWS(), DummyWS()
        await manager.connect(anonymous)  # type: ignore
        await manager.connect(authenticated, authenticated=True)  # type: ignore

        await manager.broadcast("ORDER_PAID", {"order_id": "123", "paid_xof": 15000})

        assert anonymous.sent == [{"type": "ORDER_PAID", "data": {}}]
        assert authenticated.sent[0]["data"]["paid_xof"] == 15000

    asyncio.run(_test())


def test_broadcast_sync_from_a_thread_without_event_loop():
    """Les routes synchrones tournent dans le pool de threads : la diffusion doit partir quand
    même, par la boucle de l'application."""

    async def _test():
        manager = WebSocketManager()
        dummy = DummyWS()
        await manager.connect(dummy, authenticated=True)  # type: ignore

        thread = threading.Thread(target=manager.broadcast_sync, args=("ORDER_CREATED", {"id": "o1"}))
        thread.start()
        thread.join()
        for _ in range(50):
            if dummy.sent:
                break
            await asyncio.sleep(0.01)

        assert dummy.sent == [{"type": "ORDER_CREATED", "data": {"id": "o1"}}]

    asyncio.run(_test())


def test_websocket_endpoint_connection():
    client = TestClient(app)
    with client.websocket_connect("/api/v1/ws") as websocket:
        websocket.send_text("ping")
        data = websocket.receive_text()
        assert data == "pong"


def test_websocket_with_access_token(client: TestClient):
    token = create_access_token("usr-admin-01", "ADMIN")
    with client.websocket_connect(f"/api/v1/ws?token={token}") as websocket:
        websocket.send_text("ping")
        assert websocket.receive_text() == "pong"


@pytest.mark.parametrize(
    "token",
    [
        "pas-un-jeton",
        create_refresh_token("usr-admin-01"),
        create_override_token("usr-resp-01", "Kouassi Responsable", "order.cancel"),
        create_access_token("utilisateur-inconnu", "ADMIN"),
    ],
)
def test_websocket_rejects_invalid_tokens(client: TestClient, token: str):
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect(f"/api/v1/ws?token={token}") as websocket:
            websocket.receive_text()
    assert exc.value.code == 1008


def test_websocket_requires_token_when_configured(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(get_settings(), "WS_REQUIRE_AUTH", True)
    with pytest.raises(WebSocketDisconnect) as exc:
        with TestClient(app).websocket_connect("/api/v1/ws") as websocket:
            websocket.receive_text()
    assert exc.value.code == 1008


@pytest.mark.parametrize(
    "token",
    [
        create_refresh_token("usr-admin-01"),
        create_override_token("usr-admin-01", "Isaac Admin", "order.cancel"),
    ],
)
def test_only_access_tokens_open_the_api(client: TestClient, token: str):
    response = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401

    access = create_access_token("usr-admin-01", "ADMIN")
    response = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {access}"})
    assert response.status_code == 200
