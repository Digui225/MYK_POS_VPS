import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from caisse.domain.enums import PrintJobStatus, PrintJobType
from caisse.schemas.common import Schema


class PrintingStatusOut(Schema):
    agent_online: bool = Field(description="Un agent d'impression s'est signalé récemment")
    printer_online: bool = Field(description="L'imprimante répond à l'agent")
    paper: str | None = Field(description="État du papier (`ok`, `low`…), selon l'agent")
    width: int | None = Field(description="Largeur en caractères rapportée par l'agent")
    agent_last_seen_at: datetime | None = Field(
        default=None, description="Dernière interrogation de l'agent"
    )
    queued_jobs: int = Field(description="Travaux en file (`QUEUED`)")
    failed_jobs: int = Field(description="Travaux en échec (`FAILED`)")
    last_success_at: datetime | None = Field(description="Dernière impression réussie")


class PrintJobOut(Schema):
    id: uuid.UUID = Field(description="Identifiant du travail d'impression")
    type: PrintJobType = Field(
        description="RECEIPT, X_REPORT, Z_REPORT, FNE, ORDER_TICKET, DRAWER ou TEST"
    )
    order_id: uuid.UUID | None = Field(description="Commande concernée, s'il y en a une")
    session_id: uuid.UUID | None = Field(description="Session de caisse concernée, s'il y en a une")
    status: PrintJobStatus = Field(
        description="QUEUED (en attente de l'agent), PRINTING (pris par l'agent), DONE ou FAILED"
    )
    open_drawer: bool = Field(description="Le travail ouvre le tiroir")
    attempts: int = Field(description="Nombre de prises par un agent")
    last_error: str | None = Field(description="Dernière erreur, le cas échéant")
    is_reprint: bool = Field(description="Ré-impression d'un ticket déjà imprimé")
    created_at: datetime = Field(description="Date de création du travail")


# --- Agent du terminal ---------------------------------------------------------------------


class PrinterReport(Schema):
    online: bool = Field(description="L'imprimante répond")
    paper: str | None = Field(default=None, max_length=16, description="`ok`, `near_end`…")
    model: str | None = Field(default=None, max_length=64, description="Modèle ou identifiant")
    width: int | None = Field(default=None, ge=16, le=96, description="Caractères par ligne")


class AgentPollIn(Schema):
    printer: PrinterReport = Field(description="État de l'imprimante vu par l'agent")


class AgentJobOut(Schema):
    id: uuid.UUID = Field(description="À renvoyer dans `POST /print-agent/jobs/{id}/result`")
    type: PrintJobType = Field(description="Nature du travail")
    content: str = Field(description="Texte déjà mis en page ; vide pour `DRAWER`")
    open_drawer: bool = Field(description="Envoyer l'impulsion du tiroir avant le texte")
    cut: bool = Field(description="Couper le papier après le texte")
    is_reprint: bool = Field(description="Ré-impression d'un ticket déjà imprimé")


class AgentPollOut(Schema):
    job: AgentJobOut | None = Field(description="Travail pris par ce terminal, ou null")


class AgentResultIn(Schema):
    printed: bool = Field(description="Le travail est sorti (impulsion envoyée pour `DRAWER`)")
    error: str | None = Field(default=None, max_length=500, description="Cause de l'échec")


# --- Terminaux (ADMIN) ---------------------------------------------------------------------


class PrintTerminalCreate(Schema):
    name: str = Field(min_length=1, max_length=60, examples=["Comptoir"])


class PrintTerminalOut(Schema):
    id: uuid.UUID = Field(description="Identifiant du terminal")
    name: str = Field(description="Nom du terminal")
    revoked_at: datetime | None = Field(description="Révocation du jeton ; null : actif")
    last_seen_at: datetime | None = Field(description="Dernière interrogation de son agent")
    printer_status: dict[str, Any] = Field(description="Dernier état d'imprimante rapporté")
    created_at: datetime = Field(description="Date de création")


class PrintTerminalCreated(Schema):
    terminal: PrintTerminalOut = Field(description="Terminal créé")
    token: str = Field(description="Jeton de l'agent : affiché **une seule fois**, non stocké")
