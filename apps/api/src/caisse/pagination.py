"""Pagination par curseur (keyset) des listes qui grossissent avec le temps.

Tri du plus récent au plus ancien sur (horodatage, id) : l'id départage les lignes créées
dans la même transaction (même `now()`). Le curseur est opaque pour le client : il le renvoie
tel quel, avec les mêmes filtres, pour obtenir la page suivante.
"""

import base64
import binascii
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import Select, tuple_
from sqlalchemy.orm import InstrumentedAttribute

from caisse.errors import ValidationError

DEFAULT_LIMIT = 100
MAX_LIMIT = 500


@dataclass(frozen=True)
class Cursor:
    at: datetime
    id: str


@dataclass(frozen=True)
class PageRequest:
    after: Cursor | None = None
    limit: int = DEFAULT_LIMIT


def encode_cursor(at: datetime, row_id: str | uuid.UUID) -> str:
    raw = f"{at.isoformat()}|{row_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(value: str | None) -> Cursor | None:
    if not value:
        return None
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode()
        at, row_id = raw.split("|", 1)
        parsed_at = datetime.fromisoformat(at)
        if parsed_at.tzinfo is None:
            parsed_at = parsed_at.replace(tzinfo=timezone.utc)
        cursor = Cursor(at=parsed_at, id=str(row_id))
    except (binascii.Error, UnicodeDecodeError, ValueError):
        raise ValidationError(
            "Curseur invalide",
            meta={"fields": [{"loc": ["query", "cursor"], "type": "invalid"}]},
        ) from None
    return cursor


def newest_first[*Ts](
    stmt: Select[*Ts],
    at: InstrumentedAttribute[Any],
    row_id: InstrumentedAttribute[Any],
    page: PageRequest,
) -> Select[*Ts]:
    """Trie du plus récent au plus ancien et lit une ligne de plus que la page, pour savoir
    s'il en reste."""
    if page.after is not None:
        stmt = stmt.where(tuple_(at, row_id) < tuple_(page.after.at, page.after.id))
    return stmt.order_by(at.desc(), row_id.desc()).limit(page.limit + 1)


def split[T](
    rows: Sequence[T], page: PageRequest, key: Callable[[T], tuple[datetime, Any]]
) -> tuple[list[T], str | None]:
    """(lignes de la page, curseur de la suivante ou None si c'est la dernière)."""
    if len(rows) <= page.limit:
        return list(rows), None
    items = list(rows[: page.limit])
    return items, encode_cursor(*key(items[-1]))
