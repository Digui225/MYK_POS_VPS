import hashlib
import json
from typing import Annotated, Any

from fastapi import Depends, Header, Response, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.core.errors import CaisseException, IdempotencyConflictError
from caisse.models.idempotency import IdempotencyRecord


def require_idempotency_key(
    idempotency_key: str | None = Header(
        None, alias="Idempotency-Key", max_length=64, description="Clé unique générée par le front"
    ),
) -> str:
    if not idempotency_key:
        raise CaisseException(
            code="IDEMPOTENCY_KEY_REQUIRED",
            title="Clé d'idempotence manquante",
            detail="L'en-tête Idempotency-Key est obligatoire pour cette opération financière.",
            status_code=status.HTTP_400_BAD_REQUEST,
        )
    return idempotency_key


IdempotencyKey = Annotated[str, Depends(require_idempotency_key)]

OptionalIdempotencyKey = Annotated[
    str | None,
    Header(alias="Idempotency-Key", max_length=64, description="Clé unique générée par le front (optionnelle)"),
]


def hash_request(body: BaseModel | dict[str, Any] | None = None) -> str:
    if body is None:
        return hashlib.sha256(b"").hexdigest()
    if isinstance(body, BaseModel):
        canonical = body.model_dump_json(exclude_none=False, by_alias=True).encode("utf-8")
    elif isinstance(body, dict):
        canonical = json.dumps(body, sort_keys=True, default=str).encode("utf-8")
    else:
        canonical = str(body).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def find_replay(
    db: Session, key: str, *, method: str = "POST", path: str, request_hash: str
) -> dict[str, Any] | None:
    """`None` si la clé est neuve. Sinon la réponse d'origine à rejouer telle quelle."""
    record = db.scalar(select(IdempotencyRecord).where(IdempotencyRecord.key == key))
    if record is None:
        return None
    rec_path = record.request_path.rstrip("/")
    chk_path = path.rstrip("/")
    if rec_path != chk_path or (record.request_hash and record.request_hash != request_hash):
        raise IdempotencyConflictError(meta={"key": key})
    return record.response_body


def save(
    db: Session,
    key: str,
    *,
    method: str = "POST",
    path: str,
    request_hash: str,
    status: int = 201,
    body: dict[str, Any],
    user_id: str | None = None,
) -> None:
    db.add(
        IdempotencyRecord(
            key=key,
            request_path=path,
            request_hash=request_hash,
            response_status=status,
            response_body=body,
        )
    )


def apply_replay_headers(response: Response) -> None:
    response.status_code = status.HTTP_200_OK
    response.headers["Idempotent-Replay"] = "true"
