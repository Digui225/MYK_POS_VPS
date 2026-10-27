import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status

from caisse.core.config import get_settings
from caisse.core.database import SessionLocal
from caisse.core.security import decode_token
from caisse.infrastructure.websocket.manager import ws_manager
from caisse.repositories.users import UserRepository

logger = logging.getLogger(__name__)

router = APIRouter(tags=["WebSocket"])


def _authenticate(token: str | None) -> bool | None:
    """True : jeton d'accès valide d'un utilisateur actif ; False : pas de jeton ;
    None : jeton présent mais refusé."""
    if not token:
        return False
    try:
        payload = decode_token(token)
    except Exception:
        return None
    if payload.get("type") != "access" or not payload.get("sub"):
        return None
    with SessionLocal() as db:
        user = UserRepository(db).get_by_id(payload["sub"])
        return True if user is not None and user.is_active else None


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """Point d'entrée WebSocket pour les notifications temps réel (commandes, paiements, caisse).

    Jeton d'accès en paramètre : `/api/v1/ws?token=<access_token>` (un navigateur ne peut pas
    envoyer d'en-tête Authorization à l'ouverture d'un WebSocket). Sans jeton : refusé si
    WS_REQUIRE_AUTH, sinon accepté avec le seul type des événements.
    """
    authenticated = _authenticate(websocket.query_params.get("token"))
    if authenticated is None or (authenticated is False and get_settings().WS_REQUIRE_AUTH):
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    await ws_manager.connect(websocket, authenticated=authenticated)
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
