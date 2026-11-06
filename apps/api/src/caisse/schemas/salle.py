from datetime import date
from typing import Literal

from pydantic import Field

from caisse.schemas.common import BaseSchema
from caisse.schemas.orders import ServiceModeName


class MyServiceNote(BaseSchema):
    """Une note en cours du serveur (sur une table ou sans table)."""

    order_id: str
    order_number: str
    service_mode: ServiceModeName
    table_id: str | None = None
    table_label: str | None = None
    note_label: str | None = None
    guests_count: int = 1
    total_ttc_xof: int = 0
    due_xof: int = 0
    dispatch_count: int = 0
    bill_requested_at: str | None = None
    opened_at: str


class MyServiceEvent(BaseSchema):
    """Un fait du service, pour « Le fil » : envoi, addition demandée, règlement."""

    kind: Literal["DISPATCH", "BILL_REQUESTED", "PAID"]
    at: str
    order_id: str
    order_number: str
    service_mode: ServiceModeName
    table_label: str | None = None
    note_label: str | None = None
    dispatch_no: int | None = Field(None, description="DISPATCH : numéro d'envoi")
    kitchen_count: int = Field(0, description="DISPATCH : articles partis sur le bon cuisine")
    drinks_count: int = Field(0, description="DISPATCH : boissons préparées à la caisse")
    amount_xof: int = Field(0, description="BILL_REQUESTED : reste dû ; PAID : montant réglé")
    method: str | None = Field(None, description="PAID : moyen de paiement")
    cashier_name: str | None = Field(None, description="PAID : qui a encaissé")


class MyServiceResponse(BaseSchema):
    """Le service du serveur connecté, sur la session de caisse en cours (écran « Mon service »)."""

    business_date: date | None = Field(None, description="Journée de la caisse ouverte ; nulle si fermée")
    started_at: str | None = Field(None, description="Première note ou premier envoi du serveur")
    handed_xof: int = Field(0, description="Argent remis à la caisse (paiements dont il est « remis par »)")
    settled_notes_count: int = Field(0, description="Notes du serveur réglées pendant la session")
    open_xof: int = Field(0, description="Reste dû sur ses notes en cours")
    open_notes: list[MyServiceNote] = []
    feed: list[MyServiceEvent] = []
