import logging
import threading
import time
from collections import defaultdict
from collections.abc import Callable

from fastapi import Request, status

from caisse.errors import CaisseException

logger = logging.getLogger("caisse.security")


class InMemoryRateLimiter:
    """Limiteur de débit en mémoire basé sur une fenêtre glissante (sliding window log).

    Thread-safe et asyncio-safe. Conçu pour le fonctionnement local du point de vente
    sans nécessiter de service externe (Redis).
    """

    def __init__(self) -> None:
        self._history: dict[str, list[float]] = defaultdict(list)
        self._lock = threading.Lock()

    def check(self, key: str, max_requests: int, window_seconds: int) -> tuple[bool, int]:
        """Vérifie si une requête sous la clé `key` est autorisée.

        Retourne un tuple `(is_allowed, retry_after_seconds)`.
        """
        now = time.monotonic()
        cutoff = now - window_seconds
        with self._lock:
            timestamps = [ts for ts in self._history[key] if ts > cutoff]
            if len(timestamps) >= max_requests:
                earliest = timestamps[0]
                retry_after = max(1, int(window_seconds - (now - earliest)))
                self._history[key] = timestamps
                return False, retry_after

            timestamps.append(now)
            self._history[key] = timestamps
            return True, 0

    def reset(self) -> None:
        """Réinitialise les compteurs (utile pour les tests et la maintenance)."""
        with self._lock:
            self._history.clear()


# Instance singleton du limiteur en mémoire pour l'application
rate_limiter = InMemoryRateLimiter()


def require_rate_limit(
    max_requests: int = 10,
    window_seconds: int = 60,
    key_prefix: str = "ip",
) -> Callable[[Request], None]:
    """Dépendance FastAPI appliquant une restriction de taux de requêtes par IP."""

    def dependency(request: Request) -> None:
        client_ip = request.client.host if request.client else "unknown"
        endpoint = request.url.path
        key = f"{key_prefix}:{endpoint}:{client_ip}"

        is_allowed, retry_after = rate_limiter.check(
            key=key,
            max_requests=max_requests,
            window_seconds=window_seconds,
        )

        if not is_allowed:
            logger.warning(
                "Rate limit dépassé sur %s depuis l'adresse IP %s (max: %d en %ds)",
                endpoint,
                client_ip,
                max_requests,
                window_seconds,
            )
            raise CaisseException(
                code="RATE_LIMIT_EXCEEDED",
                title="Trop de requêtes",
                detail=f"Limite de requêtes atteinte ({max_requests} requêtes / {window_seconds}s). Veuillez réessayer dans {retry_after} secondes.",
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                meta={"retry_after": retry_after, "limit": max_requests, "window": window_seconds},
            )

    return dependency
