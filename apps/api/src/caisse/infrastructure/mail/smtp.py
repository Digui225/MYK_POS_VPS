"""Envoi d'un mail par un relais SMTP standard (turboSMTP, Brevo, Gmail…).

La configuration vient de `SMTP_*` (caisse.core.config) : changer de fournisseur ne demande que
de modifier le fichier d'environnement du serveur.
"""

import smtplib
import ssl
from dataclasses import dataclass, field
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

from caisse.core.config import Settings, get_settings


class MailNotConfiguredError(RuntimeError):
    """Aucun relais SMTP configuré (SMTP_HOST ou SMTP_FROM vide)."""


@dataclass(frozen=True)
class MailAttachment:
    filename: str
    content: bytes
    mime_type: str = "application/pdf"


@dataclass(frozen=True)
class OutgoingMail:
    to: list[str]
    subject: str
    text: str
    attachments: list[MailAttachment] = field(default_factory=list)


def build_message(mail: OutgoingMail, settings: Settings) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = formataddr((settings.SMTP_FROM_NAME, settings.SMTP_FROM))
    msg["To"] = ", ".join(mail.to)
    msg["Subject"] = mail.subject
    domain = settings.SMTP_FROM.rsplit("@", 1)[-1] or None
    msg["Message-ID"] = make_msgid(domain=domain)
    msg.set_content(mail.text)
    for att in mail.attachments:
        maintype, _, subtype = att.mime_type.partition("/")
        msg.add_attachment(att.content, maintype=maintype, subtype=subtype, filename=att.filename)
    return msg


def send_mail(mail: OutgoingMail, settings: Settings | None = None) -> None:
    """Envoie le mail ; lève une exception en cas d'échec (l'outbox réessaiera)."""
    settings = settings or get_settings()
    if not settings.mail_enabled:
        raise MailNotConfiguredError("Envoi de mails non configuré (SMTP_HOST / SMTP_FROM)")
    if not mail.to:
        raise ValueError("Aucun destinataire")

    msg = build_message(mail, settings)
    host, port, timeout = settings.SMTP_HOST.strip(), settings.SMTP_PORT, settings.SMTP_TIMEOUT_SECONDS
    context = ssl.create_default_context()
    smtp: smtplib.SMTP
    if settings.SMTP_SECURITY == "ssl":
        smtp = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
    else:
        smtp = smtplib.SMTP(host, port, timeout=timeout)
    with smtp:
        if settings.SMTP_SECURITY == "starttls":
            smtp.starttls(context=context)
        if settings.SMTP_USERNAME:
            smtp.login(settings.SMTP_USERNAME, settings.SMTP_PASSWORD)
        smtp.send_message(msg)
