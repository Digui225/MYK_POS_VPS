import hashlib
from typing import Annotated, Any
from fastapi import Header
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.errors import IdempotencyConflictError
from caisse.models.idempotency import IdempotencyRecord

IdempotencyKey = Annotated[
    str,
    Header(alias="Idempotency-Key", max_length=64, description="Clé unique générée par le front"),
]


def hash_request(body: BaseModel) -> str:
    canonical = body.model_dump_json(exclude_none=False, by_alias=True).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def find_replay(
    db: Session, key: str, *, method: str, path: str, request_hash: str
) -> dict[str, Any] | None:
    """`None` si la clé est neuve. Sinon la réponse d'origine à rejouer telle quelle."""
    record = db.scalar(select(IdempotencyRecord).where(IdempotencyRecord.key == key))
    if record is None:
        return None
    if record.request_path != path or (record.request_hash and record.request_hash != request_hash):
        raise IdempotencyConflictError(meta={"key": key})
    return record.response_body


def save(
    db: Session,
    key: str,
    *,
    method: str,
    path: str,
    request_hash: str,
    status: int,
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
