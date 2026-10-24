import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from caisse.infrastructure.websocket.manager import ws_manager

logger = logging.getLogger(__name__)

router = APIRouter(tags=["WebSocket"])


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """Point d'entrée WebSocket pour les notifications temps réel (commandes, paiements, caisse)."""
    await ws_manager.connect(websocket)
    try:
        while True:
            # Attend les messages ping/pong du client ou messages éventuels
            data = await websocket.receive_text()
            if data == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        ws_manager.disconnect(websocket)
    except Exception as exc:
        logger.debug(f"Déconnexion inattendue WebSocket: {exc}")
        ws_manager.disconnect(websocket)
