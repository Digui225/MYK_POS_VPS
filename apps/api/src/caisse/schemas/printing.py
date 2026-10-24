from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class PrinterReport(BaseModel):
    online: bool = Field(description="L'imprimante répond")
    paper: str | None = Field(default=None, max_length=16, description="`ok`, `near_end`, `empty`…")
    model: str | None = Field(default=None, max_length=64, description="Modèle ou identifiant")
    width: int | None = Field(default=None, ge=16, le=96, description="Caractères par ligne")


class AgentPollIn(BaseModel):
    printer: PrinterReport = Field(description="État de l'imprimante vu par l'agent")


class AgentJobOut(BaseModel):
    id: str = Field(description="À renvoyer dans POST /print-agent/jobs/{id}/result")
    type: str = Field(description="Nature du travail : RECEIPT, DUPLICATE, Z_REPORT, X_REPORT, DRAWER, TEST")
    content: str = Field(description="Texte déjà mis en page ; vide pour DRAWER")
    open_drawer: bool = Field(description="Envoyer l'impulsion du tiroir avant le texte")
    cut: bool = Field(description="Couper le papier après le texte")
    is_reprint: bool = Field(default=False, description="Ré-impression d'un ticket déjà imprimé")


class AgentPollOut(BaseModel):
    job: AgentJobOut | None = Field(default=None, description="Travail pris par ce terminal, ou null")


class AgentResultIn(BaseModel):
    printed: bool = Field(description="Le travail est sorti (impulsion envoyée pour DRAWER)")
    error: str | None = Field(default=None, max_length=500, description="Cause de l'échec")


class PrintTerminalCreate(BaseModel):
    name: str = Field(min_length=1, max_length=60, examples=["Comptoir"])


class PrintTerminalOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str = Field(description="Identifiant du terminal")
    name: str = Field(description="Nom du terminal")
    revoked_at: datetime | None = Field(default=None, description="Révocation du jeton ; null si actif")
    last_seen_at: datetime | None = Field(default=None, description="Dernière interrogation de son agent")
    printer_status: dict[str, Any] = Field(default_factory=dict, description="Dernier état d'imprimante rapporté")
    created_at: datetime = Field(description="Date de création")


class PrintTerminalCreated(BaseModel):
    terminal: PrintTerminalOut = Field(description="Terminal créé")
    token: str = Field(description="Jeton de l'agent : affiché une seule fois, non stocké")


class PrintingStatusOut(BaseModel):
    agent_online: bool = Field(description="Un agent d'impression s'est signalé récemment")
    printer_online: bool = Field(description="L'imprimante répond à l'agent")
    paper: str | None = Field(default=None, description="État du papier (ok, low…)")
    width: int | None = Field(default=None, description="Largeur en caractères")
    agent_last_seen_at: datetime | None = Field(default=None, description="Dernière interrogation de l'agent")
    queued_jobs: int = Field(description="Travaux en file (QUEUED)")
    failed_jobs: int = Field(description="Travaux en échec (FAILED)")
    last_success_at: datetime | None = Field(default=None, description="Dernière impression réussie")


class PrintJobOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str = Field(description="Identifiant du travail d'impression")
    type: str = Field(alias="job_type", description="RECEIPT, DUPLICATE, Z_REPORT, X_REPORT, DRAWER, TEST")
    order_id: str | None = Field(default=None, description="Commande concernée")
    status: str = Field(description="QUEUED, PRINTING, DONE, FAILED")
    open_drawer: bool = Field(description="Le travail ouvre le tiroir")
    attempts: int = Field(default=0, description="Nombre de prises par un agent")
    error_message: str | None = Field(default=None, description="Dernière erreur")
    is_duplicate: bool = Field(default=False, description="Duplicata de ticket")
    created_at: datetime = Field(description="Date de création")
