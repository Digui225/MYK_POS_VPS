import asyncio
import logging
from typing import Any

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class WebSocketManager:
    """Gestionnaire de connexions WebSocket en mémoire pour diffusion d'événements temps réel.

    Un client authentifié (jeton d'accès) reçoit le détail des événements ; un client anonyme
    (toléré tant que WS_REQUIRE_AUTH est faux) ne reçoit que leur type, qui suffit au front
    pour rafraîchir ses données par l'API.
    """

    def __init__(self) -> None:
        self.active_connections: dict[WebSocket, bool] = {}
        # Boucle de l'application : les routes synchrones tournent dans des threads sans boucle,
        # la diffusion y est confiée à celle-ci.
        self._loop: asyncio.AbstractEventLoop | None = None

    async def connect(self, websocket: WebSocket, authenticated: bool = False) -> None:
        await websocket.accept()
        self._loop = asyncio.get_running_loop()
        self.active_connections[websocket] = authenticated
        logger.info(f"WebSocket client connecté. Actifs: {len(self.active_connections)}")

    def disconnect(self, websocket: WebSocket) -> None:
        self.active_connections.pop(websocket, None)
        logger.info(f"WebSocket client déconnecté. Actifs: {len(self.active_connections)}")

    async def broadcast(self, event_type: str, data: dict[str, Any] | None = None) -> None:
        """Diffuse un événement JSON à tous les clients connectés."""
        if not self.active_connections:
            return

        full = {"type": event_type, "data": data or {}}
        anonymous = {"type": event_type, "data": {}}

        stale: list[WebSocket] = []
        for connection, authenticated in list(self.active_connections.items()):
            try:
                await connection.send_json(full if authenticated else anonymous)
            except Exception as exc:
                logger.debug(f"Erreur d'envoi WebSocket, déconnexion: {exc}")
                stale.append(connection)

        for conn in stale:
            self.active_connections.pop(conn, None)

    def broadcast_sync(self, event_type: str, data: dict[str, Any] | None = None) -> None:
        """Déclenche la diffusion depuis une fonction ou un service synchrone."""
        try:
            asyncio.get_running_loop().create_task(self.broadcast(event_type, data))
            return
        except RuntimeError:
            pass
        # Route synchrone (thread du pool) : aucune boucle ici, on passe par celle de l'application.
        loop = self._loop
        if loop is not None and loop.is_running() and self.active_connections:
            asyncio.run_coroutine_threadsafe(self.broadcast(event_type, data), loop)


ws_manager = WebSocketManager()
