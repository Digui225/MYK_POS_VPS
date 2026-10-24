import hashlib
import secrets
from datetime import datetime, timezone

from fastapi import status
from sqlalchemy.orm import Session

from caisse.errors import CaisseException
from caisse.models.print_terminal import PrintTerminal
from caisse.repositories.print_terminals import PrintTerminalRepository
from caisse.services.audit_service import AuditService

TOKEN_PREFIX = "pt_"


def hash_terminal_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class PrintTerminalService:
    def __init__(self, db: Session):
        self.db = db
        self.repo = PrintTerminalRepository(db)
        self.audit = AuditService(db)

    def create_terminal(
        self, name: str, user_id: str | None = None, device_id: str | None = None
    ) -> tuple[PrintTerminal, str]:
        """Crée un terminal d'impression et renvoie (terminal, jeton_en_clair).
        Le jeton en clair n'est affiché qu'une seule fois et n'est jamais stocké."""
        existing = self.repo.by_name(name)
        if existing:
            raise CaisseException(
                code="PRINT_TERMINAL_NAME_EXISTS",
                title="Nom de terminal déjà utilisé",
                detail=f"Un terminal d'impression nommé « {name} » existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )

        token = TOKEN_PREFIX + secrets.token_urlsafe(32)
        token_hash = hash_terminal_token(token)

        terminal = PrintTerminal(
            name=name,
            token_hash=token_hash,
            printer_status={},
            created_by=user_id,
        )
        self.repo.add(terminal)
        self.db.flush()

        self.audit.log(
            action="PRINT_TERMINAL_CREATED",
            entity="PRINT_TERMINAL",
            entity_id=terminal.id,
            user_id=user_id,
            after={"name": name},
            device_id=device_id,
        )
        self.db.commit()
        return terminal, token

    def revoke_terminal(
        self, terminal_id: str, user_id: str | None = None, device_id: str | None = None
    ) -> PrintTerminal:
        terminal = self.repo.get(terminal_id)
        if not terminal:
            raise CaisseException(
                code="TERMINAL_NOT_FOUND",
                title="Terminal introuvable",
                detail=f"Terminal d'impression {terminal_id} introuvable.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if terminal.revoked_at is None:
            terminal.revoked_at = datetime.now(timezone.utc)
            self.audit.log(
                action="PRINT_TERMINAL_REVOKED",
                entity="PRINT_TERMINAL",
                entity_id=terminal.id,
                user_id=user_id,
                after={"name": terminal.name},
                device_id=device_id,
            )
            self.db.commit()

        return terminal

    def list_terminals(self) -> list[PrintTerminal]:
        return self.repo.list_all()

    def authenticate(self, token: str) -> PrintTerminal:
        token_hash = hash_terminal_token(token)
        terminal = self.repo.active_by_token_hash(token_hash)
        if not terminal:
            raise CaisseException(
                code="TERMINAL_TOKEN_INVALID",
                title="Jeton de terminal invalide",
                detail="Jeton d'agent d'impression inconnu ou révoqué.",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )
        return terminal
