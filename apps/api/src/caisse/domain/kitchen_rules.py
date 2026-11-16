"""Bon cuisine : quelles lignes partent en cuisine et texte imprimé à la caisse (58 mm).

Les boissons restent à la caisse : une ligne part en cuisine sauf si sa catégorie est
une boisson (`DRINK`). Une saisie hors menu sans catégorie part en cuisine, par prudence.

Depuis D18 (16/11/2026), le bon porte le prix de chaque ligne et le total de l'envoi, et il
est mis en forme pour être lu de loin : bandeau « CUISINE » en blanc sur noir, lieu en double
taille, plats en gras et en double hauteur. La mise en forme passe par des codes ESC/POS
insérés dans le texte ; l'agent d'impression les transmet tels quels à l'imprimante.
"""

from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Africa/Abidjan")

SERVICE_MODE_LABELS = {"EMPORTER": "A EMPORTER", "LIVRAISON": "LIVRAISON"}

# Codes ESC/POS, sans octet nul (une colonne texte PostgreSQL ne peut pas le stocker) :
# `ESC !` règle gras et taille ensemble, `GS B 1` passe en blanc sur noir.
_ESC_BOLD = "\x1b!\x08"  # gras, taille normale
_ESC_TALL = "\x1b!\x18"  # gras, double hauteur
_ESC_BIG = "\x1b!\x38"  # gras, double hauteur et double largeur
_ESC_REVERSE = "\x1d\x42\x01"
# Retour au texte normal, toujours après un saut de ligne (ESC @ vide la ligne en cours) ;
# FS . annule le mode caractères chinois des Xprinter, comme le fait l'agent au démarrage.
_ESC_RESET = "\x1b@\x1c."

# Style d'un segment : (code ESC/POS, colonnes occupées par caractère)
_STYLES = {
    "normal": ("", 1),
    "bold": (_ESC_BOLD, 1),
    "tall": (_ESC_TALL, 1),
    "big": (_ESC_BIG, 2),
    "banner": (_ESC_REVERSE + _ESC_BIG, 2),
}


def is_kitchen_line(category_kind: str | None) -> bool:
    """Vrai si la ligne doit figurer sur le bon cuisine (tout sauf les boissons)."""
    return category_kind != "DRINK"


@dataclass(frozen=True)
class KitchenLine:
    quantity: int
    name: str
    note: str | None = None
    seat: int | None = None
    line_total_xof: int = 0


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
    # Ajout : plats des envois précédents (rappel sans prix) et heure du premier envoi
    already_sent: tuple[KitchenLine, ...] = ()
    first_sent_at: datetime | None = None
    # Total de la note, boissons comprises (affiché sur un ajout)
    order_total_xof: int | None = None


@dataclass(frozen=True)
class Segment:
    text: str
    style: str = "normal"

    @property
    def columns(self) -> int:
        return len(self.text) * _STYLES[self.style][1]


Line = tuple[Segment, ...]


def line_columns(line: Line) -> int:
    """Colonnes occupées sur le papier (un caractère en double largeur en prend deux)."""
    return sum(seg.columns for seg in line)


def format_xof(amount: int) -> str:
    return f"{amount:,}".replace(",", " ")


def _seat_label(seat: int | None) -> str | None:
    if seat is None:
        return None
    return "pour la table" if seat == 0 else f"convive {seat}"


def _wrap(text: str, first: str, rest: str, width: int, first_width: int | None = None) -> list[str]:
    """Coupe `text` : 1re ligne préfixée par `first` sur `first_width` colonnes (par défaut
    `width`), suivantes préfixées par `rest` sur `width` colonnes."""
    lines: list[str] = []
    current = ""

    def limit() -> int:
        return first_width if not lines and first_width is not None else width

    for word in text.split():
        prefix = first if not lines else rest
        candidate = f"{current} {word}" if current else word
        if len(prefix) + len(candidate) <= limit():
            current = candidate
            continue
        if current:
            lines.append(prefix + current)
            prefix = rest
        current = word[: limit() - len(prefix)]
    if current:
        lines.append((first if not lines else rest) + current)
    return lines


def _row(left: Segment, right: Segment, width: int) -> Line:
    """`left` à gauche, `right` calé à droite ; `left` est tronqué si la ligne déborde."""
    per_char = _STYLES[left.style][1]
    space = width - left.columns - right.columns
    if space < 1:
        keep = max(0, (width - right.columns - 1) // per_char)
        left = Segment(left.text[:keep], left.style)
        space = width - left.columns - right.columns
    return (left, Segment(" " * space, left.style if per_char == 1 else "bold"), right)


def kitchen_ticket_layout(ticket: KitchenTicket, width: int = 32) -> list[Line]:
    """Mise en page du bon cuisine, ligne par ligne, chaque ligne tenant sur `width` colonnes."""
    sep: Line = (Segment("-" * width),)
    blank: Line = (Segment(""),)

    if ticket.service_mode in SERVICE_MODE_LABELS:
        place = SERVICE_MODE_LABELS[ticket.service_mode]
    else:
        place = (ticket.table_label or "TABLE").upper()
        if ticket.note_label:
            place = f"{place} - {ticket.note_label}"
    place = place.upper()
    envoi = Segment(f"ENVOI {ticket.dispatch_no}", "bold")
    # Lieu en double taille s'il tient avec « ENVOI n », sinon en double hauteur
    place_style = "big" if len(place) * 2 + 1 + envoi.columns <= width else "tall"

    lines: list[Line] = [
        (Segment("CUISINE".center(width // 2), "banner"),),
        blank,
        _row(Segment(place, place_style), envoi, width),
    ]
    if ticket.server_name:
        lines.append((Segment(f"Serveur : {ticket.server_name.upper()}"[:width]),))
    local_time = ticket.sent_at.astimezone(LOCAL_TZ).strftime("%H:%M")
    couverts = f"{ticket.guests_count} couvert{'s' if ticket.guests_count > 1 else ''}"
    left = f"{couverts} - " if ticket.service_mode == "SUR_PLACE" else ""
    lines.append((Segment(f"{left}{local_time}"[:width]),))
    lines.append(sep)
    if ticket.dispatch_no > 1:
        lines.append((Segment("*** AJOUT ***".center(width).rstrip(), "bold"),))

    for line in ticket.lines:
        price = format_xof(line.line_total_xof)
        name_width = width - len(price) - 1
        wrapped = _wrap(line.name.upper(), f"{line.quantity} x ", "    ", width, first_width=name_width)
        lines.append(_row(Segment(wrapped[0], "tall"), Segment(price, "tall"), width))
        lines.extend((Segment(text, "tall"),) for text in wrapped[1:])
        seat = _seat_label(line.seat)
        if seat:
            lines.append((Segment(f"    > {seat}"),))
        if line.note:
            lines.extend((Segment(text),) for text in _wrap(line.note, "    > ", "      ", width))
    lines.append(sep)
    envoi_total = sum(line.line_total_xof for line in ticket.lines)
    lines.append(_row(Segment("TOTAL ENVOI", "tall"), Segment(f"{format_xof(envoi_total)} F", "tall"), width))

    if ticket.dispatch_no > 1:
        if ticket.order_total_xof is not None:
            lines.append(
                _row(Segment("Total note"), Segment(f"{format_xof(ticket.order_total_xof)} F"), width)
            )
        if ticket.already_sent:
            lines.append(sep)
            since = (
                f" ({ticket.first_sent_at.astimezone(LOCAL_TZ).strftime('%H:%M')})"
                if ticket.first_sent_at
                else ""
            )
            lines.append((Segment(f"Déjà envoyé{since} :"),))
            recap = ", ".join(f"{it.quantity} {it.name}" for it in ticket.already_sent)
            lines.extend((Segment(text),) for text in _wrap(recap, "", "", width))

    lines.append(sep)
    lines.append((Segment(f"Cde {ticket.order_number} - envoi {ticket.dispatch_no}"[:width]),))
    return lines


def render_lines(lines: list[Line], escpos: bool = True) -> str:
    """Texte à imprimer ; sans `escpos`, le même texte sans codes (tests, aperçu)."""
    out: list[str] = []
    for line in lines:
        styled = False
        text = ""
        previous = "normal"
        for seg in line:
            code = _STYLES[seg.style][0] if escpos and seg.style != previous else ""
            previous = seg.style
            styled = styled or bool(code)
            text += code + seg.text
        out.append(text + "\n")
        if styled:
            out.append(_ESC_RESET)  # après le saut de ligne : la ligne est déjà imprimée
    return "".join(out)


def format_kitchen_ticket_text(ticket: KitchenTicket, width: int = 32, *, escpos: bool = True) -> str:
    """Texte du bon cuisine pour une imprimante thermique de `width` colonnes."""
    return render_lines(kitchen_ticket_layout(ticket, width), escpos=escpos)
