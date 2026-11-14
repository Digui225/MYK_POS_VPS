"""Envoi de mails par relais SMTP (rapport de ventes à la clôture de caisse)."""

from caisse.infrastructure.mail.smtp import (
    MailAttachment,
    MailNotConfiguredError,
    OutgoingMail,
    send_mail,
)

__all__ = ["MailAttachment", "MailNotConfiguredError", "OutgoingMail", "send_mail"]
