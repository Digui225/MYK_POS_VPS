import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.models.print_terminal import PrintTerminal


def get(db: Session, terminal_id: uuid.UUID) -> PrintTerminal | None:
    return db.get(PrintTerminal, terminal_id)


def by_name(db: Session, name: str) -> PrintTerminal | None:
    return db.scalar(select(PrintTerminal).where(PrintTerminal.name == name))


def active_by_token_hash(db: Session, token_hash: str) -> PrintTerminal | None:
    return db.scalar(
        select(PrintTerminal).where(
            PrintTerminal.token_hash == token_hash, PrintTerminal.revoked_at.is_(None)
        )
    )


def list_all(db: Session) -> list[PrintTerminal]:
    return list(db.scalars(select(PrintTerminal).order_by(PrintTerminal.created_at)))


def latest_seen(db: Session) -> PrintTerminal | None:
    """Terminal actif dont l'agent s'est signalé le plus récemment."""
    return db.scalar(
        select(PrintTerminal)
        .where(PrintTerminal.revoked_at.is_(None), PrintTerminal.last_seen_at.is_not(None))
        .order_by(PrintTerminal.last_seen_at.desc())
        .limit(1)
    )
