"""Envoi par mail du rapport de ventes de la journée (PDF) à chaque clôture de caisse.

La clôture inscrit un événement `DAILY_REPORT_EMAIL` dans l'outbox (dans la même transaction) ;
le worker produit le PDF et l'envoie par SMTP, avec les réessais de l'outbox en cas d'échec.
La clôture ne dépend donc jamais du mail. Les destinataires se règlent dans Administration
(paramètre `report.closing_email_recipients`).
"""

import logging
import re
from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.core.errors import CaisseException
from caisse.infrastructure.mail import MailAttachment, OutgoingMail, send_mail
from caisse.models.outbox import OutboxEvent
from caisse.repositories import settings as settings_repo
from caisse.schemas.reports import DashboardOut
from caisse.services import reporting_service
from caisse.services.daily_report_pdf import build_daily_report_pdf, format_day, format_xof

logger = logging.getLogger(__name__)

RECIPIENTS_KEY = "report.closing_email_recipients"
EVENT_TYPE = "DAILY_REPORT_EMAIL"
MAX_RECIPIENTS = 10
_EMAIL_RE = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+\.[A-Za-z]{2,}$")


# --- Destinataires -------------------------------------------------------------------------


def get_recipients(db: Session) -> list[str]:
    value = settings_repo.get_value(db, RECIPIENTS_KEY, [])
    return [str(v) for v in value] if isinstance(value, list) else []


def normalize_recipients(emails: list[str]) -> list[str]:
    """Adresses nettoyées (minuscules, sans doublon) ; erreur 422 si l'une est invalide."""
    cleaned: list[str] = []
    for raw in emails:
        email = raw.strip().lower()
        if not email:
            continue
        if not _EMAIL_RE.match(email):
            raise CaisseException(
                code="INVALID_EMAIL",
                title="Adresse e-mail invalide",
                detail=f"« {raw.strip()} » n'est pas une adresse e-mail valide.",
                status_code=422,
            )
        if email not in cleaned:
            cleaned.append(email)
    if len(cleaned) > MAX_RECIPIENTS:
        raise CaisseException(
            code="TOO_MANY_RECIPIENTS",
            title="Trop de destinataires",
            detail=f"{MAX_RECIPIENTS} adresses au plus pour le rapport de clôture.",
            status_code=422,
        )
    return cleaned


def set_recipients(db: Session, emails: list[str], *, user_id: str) -> list[str]:
    cleaned = normalize_recipients(emails)
    settings_repo.set_value(db, RECIPIENTS_KEY, cleaned, user_id=user_id)
    return cleaned


# --- Mise en file ----------------------------------------------------------------------------


def enqueue_daily_report(
    db: Session,
    business_date: date,
    *,
    trigger: str,
    session_id: str | None = None,
    z_number: int | None = None,
) -> OutboxEvent | None:
    """Inscrit l'envoi du rapport dans l'outbox (sans valider la transaction).

    Rien n'est inscrit sans destinataire ou sans relais SMTP configuré : pas d'événement voué
    à l'échec."""
    if not get_settings().mail_enabled or not get_recipients(db):
        return None
    event = OutboxEvent(
        event_type=EVENT_TYPE,
        aggregate_type="CashSession" if session_id else "BusinessDay",
        aggregate_id=session_id or business_date.isoformat(),
        payload={
            "business_date": business_date.isoformat(),
            "trigger": trigger,
            "session_id": session_id,
            "z_number": z_number,
        },
        status="PENDING",
    )
    db.add(event)
    return event


# --- Envoi (worker outbox) -----------------------------------------------------------------


def _closing_line(overview: DashboardOut, payload: dict[str, Any]) -> str:
    session = next((s for s in overview.sessions if s.id == payload.get("session_id")), None)
    if session is None:
        return ""
    parts = [f"Clôture de la caisse « {session.cash_register} »"]
    if session.z_number is not None:
        parts.append(f"Z n° {session.z_number}")
    if session.variance_xof is not None:
        parts.append(f"écart de caisse : {format_xof(session.variance_xof)}")
    return " — ".join(parts) + "."


def build_mail(day: date, overview: DashboardOut, pdf: bytes, payload: dict[str, Any], to: list[str]) -> OutgoingMail:
    z = payload.get("z_number")
    subject = f"Rapport de ventes — {format_day(day)}" + (f" — Z n° {z}" if z is not None else "")
    closing = _closing_line(overview, payload)
    lines = [
        "Bonjour,",
        "",
        f"Veuillez trouver ci-joint le rapport de ventes du {format_day(day)}.",
    ]
    if closing:
        lines += ["", closing]
    lines += [
        "",
        f"Chiffre d'affaires : {format_xof(overview.revenue_xof)}",
        f"Additions encaissées : {overview.orders_paid}",
        f"Panier moyen : {format_xof(overview.average_ticket_xof)}",
        f"Annulations : {overview.orders_cancelled}",
        "",
        "Si la caisse est clôturée plusieurs fois dans la journée, le dernier rapport reçu fait foi.",
        "",
        "— Caisse MYK (envoi automatique, merci de ne pas répondre)",
    ]
    return OutgoingMail(
        to=to,
        subject=subject,
        text="\n".join(lines),
        attachments=[MailAttachment(f"Rapport_Ventes_{day.isoformat()}.pdf", pdf)],
    )


def send_daily_report(db: Session, payload: dict[str, Any]) -> None:
    """Produit le PDF de la journée et l'envoie aux destinataires actuels ; lève en cas d'échec."""
    recipients = get_recipients(db)
    if not recipients:
        logger.info("Rapport de ventes non envoyé : aucun destinataire configuré")
        return
    day = date.fromisoformat(str(payload["business_date"]))
    overview = reporting_service.dashboard(db, day)
    sales = reporting_service.sales_report(db, day, day)
    pdf = build_daily_report_pdf(day, overview, sales)
    send_mail(build_mail(day, overview, pdf, payload, recipients))
    logger.info("Rapport de ventes du %s envoyé à %d destinataire(s)", day, len(recipients))
