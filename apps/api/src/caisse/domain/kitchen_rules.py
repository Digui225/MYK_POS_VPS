"""Bon cuisine : quelles lignes partent en cuisine et texte imprimé à la caisse (58 mm).

Les boissons restent à la caisse : une ligne part en cuisine sauf si sa catégorie est
une boisson (`DRINK`). Une saisie hors menu sans catégorie part en cuisine, par prudence.
Le bon ne porte aucun prix.
"""

from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Africa/Abidjan")

SERVICE_MODE_LABELS = {"EMPORTER": "A EMPORTER", "LIVRAISON": "LIVRAISON"}


def is_kitchen_line(category_kind: str | None) -> bool:
    """Vrai si la ligne doit figurer sur le bon cuisine (tout sauf les boissons)."""
    return category_kind != "DRINK"


@dataclass(frozen=True)
class KitchenLine:
    quantity: int
    name: str
    note: str | None = None
    seat: int | None = None


@dataclass(frozen=True)
class KitchenTicket:
    order_number: str
    service_mode: str
    table_label: str | None
    note_label: str | None
    server_name: str | None
    guests_count: int
    dispatch_no: int
    sent_at: datetime
    lines: tuple[KitchenLine, ...]


def _seat_label(seat: int | None) -> str | None:
    if seat is None:
        return None
    return "pour la table" if seat == 0 else f"convive {seat}"


def _wrap(text: str, first: str, rest: str, width: int) -> list[str]:
    """Coupe `text` sur `width` colonnes : 1re ligne préfixée par `first`, suivantes par `rest`."""
    lines: list[str] = []
    current = ""
    for word in text.split():
        prefix = first if not lines else rest
        candidate = f"{current} {word}" if current else word
        if len(prefix) + len(candidate) <= width:
            current = candidate
            continue
        if current:
            lines.append(prefix + current)
            prefix = rest
        current = word[: width - len(prefix)]
    if current:
        lines.append((first if not lines else rest) + current)
    return lines


def format_kitchen_ticket_text(ticket: KitchenTicket, width: int = 32) -> str:
    """Texte du bon cuisine, aligné pour une imprimante thermique de `width` colonnes."""
    rule = "=" * width
    sep = "-" * width

    def row(left: str, right: str) -> str:
        space = width - len(left) - len(right)
        if space < 1:
            left = left[: max(0, width - len(right) - 1)]
            space = 1
        return f"{left}{' ' * space}{right}"

    if ticket.service_mode in SERVICE_MODE_LABELS:
        place = SERVICE_MODE_LABELS[ticket.service_mode]
    else:
        place = (ticket.table_label or "TABLE").upper()
        if ticket.note_label:
            place = f"{place} - {ticket.note_label}"

    local_time = ticket.sent_at.astimezone(LOCAL_TZ).strftime("%H:%M")
    lines = [
        rule,
        "BON CUISINE".center(width).rstrip(),
        rule,
        row(place.upper(), f"ENVOI {ticket.dispatch_no}"),
    ]
    if ticket.server_name:
        lines.append(f"Serveur : {ticket.server_name.upper()}"[:width])
    couverts = f"{ticket.guests_count} couvert{'s' if ticket.guests_count > 1 else ''}"
    lines.append(row(couverts if ticket.service_mode == "SUR_PLACE" else "", local_time))
    lines.append(sep)
    if ticket.dispatch_no > 1:
        lines.append("*** AJOUT ***".center(width).rstrip())
        lines.append("")

    for line in ticket.lines:
        lines.extend(_wrap(line.name.upper(), f"{line.quantity} x ", "    ", width))
        seat = _seat_label(line.seat)
        if seat:
            lines.append(f"    > {seat}")
        if line.note:
            lines.extend(_wrap(line.note, "    > ", "      ", width))
    lines.append(sep)
    lines.append(f"Cde {ticket.order_number} - sans prix"[:width])
    return "\n".join(lines) + "\n"
