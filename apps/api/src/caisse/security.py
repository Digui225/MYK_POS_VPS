from datetime import datetime, timedelta, timezone
from typing import Any, cast

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import status
from jose import JWTError, jwt

from caisse.config import get_settings
from caisse.errors import CaisseException

settings = get_settings()

ph = PasswordHasher(
    time_cost=3,
    memory_cost=65536,  # 64 MB
    parallelism=4,
    hash_len=32,
    salt_len=16,
)


def utcnow() -> datetime:
    """Horodatage UTC actuel."""
    return datetime.now(timezone.utc)


def hash_pin(pin: str) -> str:
    """Hache un code PIN avec Argon2id."""
    return ph.hash(pin)


def verify_pin(pin: str, pin_hash: str) -> bool:
    """Vérifie un code PIN avec Argon2id."""
    try:
        return ph.verify(pin_hash, pin)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def create_access_token(user_id: str, role: str, device_id: str | None = None) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {
        "sub": user_id,
        "role": role,
        "device_id": device_id,
        "type": "access",
        "exp": expire,
    }
    return str(jwt.encode(to_encode, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM))


def create_refresh_token(user_id: str, device_id: str | None = None) -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=settings.REFRESH_TOKEN_EXPIRE_HOURS)
    to_encode = {
        "sub": user_id,
        "device_id": device_id,
        "type": "refresh",
        "exp": expire,
    }
    return str(jwt.encode(to_encode, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM))


def create_override_token(manager_id: str, manager_name: str, target_action: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(seconds=60)
    to_encode = {
        "sub": manager_id,
        "name": manager_name,
        "target_action": target_action,
        "type": "override",
        "exp": expire,
    }
    return str(jwt.encode(to_encode, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM))


def decode_token(token: str) -> dict[str, Any]:
    try:
        payload = jwt.decode(token, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
        return cast(dict[str, Any], payload)
    except JWTError as err:
        raise CaisseException(
            code="TOKEN_EXPIRED_OR_INVALID",
            title="Jeton de session invalide ou expiré",
            detail="Votre session a expiré ou le jeton fourni est invalide.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        ) from err
