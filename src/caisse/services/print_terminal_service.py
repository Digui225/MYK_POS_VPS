"""Terminaux d'impression : jeton de l'agent, distinct des PIN et révocable.

Le jeton est tiré au hasard (256 bits) : une empreinte SHA-256 suffit à le stocker, sans le
coût d'Argon2 que justifient les PIN courts. Il n'est montré qu'une fois, à la création ;
changer de jeton = révoquer le terminal puis en créer un nouveau.
"""

import hashlib
import secrets
import uuid
from datetime import UTC, datetime

from sqlalchemy.orm import Session

from caisse.errors import NotFoundError, PrintTerminalNameExistsError, TerminalTokenInvalidError
from caisse.models.print_terminal import PrintTerminal
from caisse.repositories import print_terminals as terminals_repo
from caisse.services import audit_service
from caisse.services.audit_service import RequestContext

TOKEN_PREFIX = "pt_"


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_terminal(
    db: Session, *, name: str, actor_id: uuid.UUID | None, ctx: RequestContext
) -> tuple[PrintTerminal, str]:
    """Renvoie (terminal, jeton en clair)."""
    if terminals_repo.by_name(db, name) is not None:
        raise PrintTerminalNameExistsError(meta={"name": name})
    token = TOKEN_PREFIX + secrets.token_urlsafe(32)
    terminal = PrintTerminal(
        name=name, token_hash=_hash(token), printer_status={}, created_by=actor_id
    )
    db.add(terminal)
    db.flush()
    audit_service.log(
        db,
        "print_terminal.create",
        ctx=ctx,
        user_id=actor_id,
        entity="print_terminal",
        entity_id=terminal.id,
        after={"name": name},
    )
    db.commit()
    return terminal, token


def revoke_terminal(
    db: Session, terminal_id: uuid.UUID, *, actor_id: uuid.UUID | None, ctx: RequestContext
) -> PrintTerminal:
    terminal = terminals_repo.get(db, terminal_id)
    if terminal is None:
        raise NotFoundError(meta={"terminal_id": str(terminal_id)})
    if terminal.revoked_at is None:
        terminal.revoked_at = datetime.now(UTC)
        audit_service.log(
            db,
            "print_terminal.revoke",
            ctx=ctx,
            user_id=actor_id,
            entity="print_terminal",
            entity_id=terminal.id,
            after={"name": terminal.name},
        )
        db.commit()
    return terminal


def list_terminals(db: Session) -> list[PrintTerminal]:
    return terminals_repo.list_all(db)


def authenticate(db: Session, token: str) -> PrintTerminal:
    terminal = terminals_repo.active_by_token_hash(db, _hash(token))
    if terminal is None:
        raise TerminalTokenInvalidError()
    return terminal
