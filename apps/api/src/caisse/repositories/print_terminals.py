from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.models.print_terminal import PrintTerminal


class PrintTerminalRepository:
    def __init__(self, db: Session):
        self.db = db

    def get(self, terminal_id: str) -> PrintTerminal | None:
        return self.db.get(PrintTerminal, terminal_id)

    def by_name(self, name: str) -> PrintTerminal | None:
        return self.db.scalar(select(PrintTerminal).where(PrintTerminal.name == name))

    def active_by_token_hash(self, token_hash: str) -> PrintTerminal | None:
        return self.db.scalar(
            select(PrintTerminal).where(
                PrintTerminal.token_hash == token_hash,
                PrintTerminal.revoked_at.is_(None),
            )
        )

    def latest_seen(self) -> PrintTerminal | None:
        return self.db.scalar(
            select(PrintTerminal)
            .where(PrintTerminal.revoked_at.is_(None), PrintTerminal.last_seen_at.is_not(None))
            .order_by(PrintTerminal.last_seen_at.desc())
            .limit(1)
        )

    def list_all(self) -> list[PrintTerminal]:
        return list(
            self.db.scalars(
                select(PrintTerminal).order_by(PrintTerminal.name.asc())
            ).all()
        )

    def add(self, terminal: PrintTerminal) -> PrintTerminal:
        self.db.add(terminal)
        self.db.flush()
        return terminal
