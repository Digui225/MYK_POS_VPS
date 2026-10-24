import asyncio
import logging
from typing import Any

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class WebSocketManager:
    """Gestionnaire de connexions WebSocket en mémoire pour diffusion d'événements temps réel."""

    def __init__(self) -> None:
        self.active_connections: set[WebSocket] = set()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self.active_connections.add(websocket)
        logger.info(f"WebSocket client connecté. Actifs: {len(self.active_connections)}")

    def disconnect(self, websocket: WebSocket) -> None:
        self.active_connections.discard(websocket)
        logger.info(f"WebSocket client déconnecté. Actifs: {len(self.active_connections)}")

    async def broadcast(self, event_type: str, data: dict[str, Any] | None = None) -> None:
        """Diffuse un événement JSON à tous les clients connectés."""
        if not self.active_connections:
            return

        payload = {
            "type": event_type,
            "data": data or {},
        }

        stale: list[WebSocket] = []
        for connection in list(self.active_connections):
            try:
                await connection.send_json(payload)
            except Exception as exc:
                logger.debug(f"Erreur d'envoi WebSocket, déconnexion: {exc}")
                stale.append(connection)

        for conn in stale:
            self.active_connections.discard(conn)

    def broadcast_sync(self, event_type: str, data: dict[str, Any] | None = None) -> None:
        """Déclenche la diffusion depuis une fonction ou un service synchrone."""
        try:
            loop = asyncio.get_running_loop()
            loop.create_task(self.broadcast(event_type, data))
        except RuntimeError:
            pass


ws_manager = WebSocketManager()
