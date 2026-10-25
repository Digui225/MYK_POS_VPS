"""Compteurs verrouillés (`sequence_counters`) : n° de demande d'achat, etc."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.models.settings import SequenceCounter


def next_value(db: Session, key: str) -> int:
    """Incrémente et retourne le compteur `key`, en le créant s'il n'existe pas.

    Compatible PostgreSQL (insert ON CONFLICT DO NOTHING) et SQLite (fallback).
    `SELECT ... FOR UPDATE` sérialise les transactions concurrentes sur la même clé.
    """
    bind = db.get_bind()
    if bind is not None and bind.dialect.name == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
        db.execute(insert(SequenceCounter).values(key=key, value=0).on_conflict_do_nothing())
    else:
        counter = db.execute(select(SequenceCounter).where(SequenceCounter.key == key)).scalar_one_or_none()
        if counter is None:
            db.add(SequenceCounter(key=key, value=0))
            db.flush()

    stmt = select(SequenceCounter).where(SequenceCounter.key == key)
    # with_for_update is supported in Postgres, can be ignored in SQLite
    if bind is not None and bind.dialect.name == "postgresql":
        stmt = stmt.with_for_update()

    counter = db.execute(stmt).scalar_one()
    counter.value += 1
    db.flush()
    return counter.value
