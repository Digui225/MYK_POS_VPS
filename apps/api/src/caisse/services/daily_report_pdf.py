"""Rapport de ventes de la journée en PDF A4, produit par le serveur (envoi par mail à la clôture).

Mêmes rubriques que l'aperçu du tableau de bord (frontend `DailySalesReportSheet`) : chiffres clés,
encaissements par moyen de paiement et par caissier, ventes par heure, détail des produits vendus
par catégorie, total général et signatures. Uniquement les ventes : ni marge, ni coût, ni stock.
"""

from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from fpdf import FPDF

from caisse.schemas.reports import DashboardOut, SalesReportOut

TZ = ZoneInfo("Africa/Abidjan")
LOGO_PATH = Path(__file__).resolve().parent.parent / "assets" / "logo_sylla.png"

DAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
MONTHS = [
    "janvier", "février", "mars", "avril", "mai", "juin",
    "juillet", "août", "septembre", "octobre", "novembre", "décembre",
]

PAYMENT_LABELS = {
    "CASH": "Espèces",
    "ESPECES": "Espèces",
    "MOBILE_MONEY": "Mobile money",
    "MOBILE_MONEY_WAVE": "Wave",
    "MOBILE_MONEY_ORANGE": "Orange Money",
    "MOBILE_MONEY_MTN": "MTN MoMo",
    "MOBILE_MONEY_MOOV": "Moov Money",
    "CARD": "Carte bancaire",
    "CARTE": "Carte bancaire",
    "BANK_TRANSFER": "Virement bancaire",
    "VIREMENT": "Virement bancaire",
}

# Couleurs (gris de l'aperçu)
INK = (24, 24, 27)
MUTED = (113, 113, 122)
LINE = (212, 212, 216)
SHADE = (244, 244, 245)
GREEN = (6, 95, 70)
AMBER = (146, 64, 14)


def format_xof(amount: int) -> str:
    sign = "-" if amount < 0 else ""
    return f"{sign}{abs(int(amount)):,}".replace(",", " ") + " FCFA"


def format_day(day: date) -> str:
    """« jeudi 12 novembre 2026 »."""
    return f"{DAYS[day.weekday()]} {day.day} {MONTHS[day.month - 1]} {day.year}"


def payment_label(method: str, provider: str | None) -> str:
    prov = (provider or "").strip().upper()
    if prov:
        return PAYMENT_LABELS.get(f"{method}_{prov}") or f"{PAYMENT_LABELS.get(method, method)} {provider}"
    return PAYMENT_LABELS.get(method, method)


def pct(part: int, total: int) -> str:
    return f"{round(part / total * 100)} %" if total else "0 %"


def status_text(overview: DashboardOut) -> tuple[str, tuple[int, int, int]]:
    """Tampon de l'en-tête : journée clôturée (n° de Z), provisoire, ou aucune session."""
    if not overview.sessions:
        return "AUCUNE SESSION DE CAISSE", MUTED
    if all(s.status == "CLOSED" for s in overview.sessions):
        z = sorted(s.z_number for s in overview.sessions if s.z_number is not None)
        suffix = f" — Z N° {', '.join(str(n) for n in z)}" if z else ""
        return f"JOURNÉE CLÔTURÉE{suffix}", GREEN
    return "PROVISOIRE — CAISSE OUVERTE", AMBER


@dataclass(frozen=True)
class ProductLine:
    kind: str  # "category" ou "product"
    label: str
    quantity: int
    unit_price_xof: int
    revenue_xof: int


def product_lines(sales: SalesReportOut) -> list[ProductLine]:
    """Produits regroupés par catégorie (catégories par CA décroissant, produits aussi)."""
    categories = [c.category for c in sales.by_category]
    for p in sales.by_product:
        if p.category not in categories:
            categories.append(p.category)
    lines: list[ProductLine] = []
    for category in categories:
        products = sorted(
            (p for p in sales.by_product if p.category == category and p.quantity != 0),
            key=lambda p: (-p.revenue_xof, p.name),
        )
        if not products:
            continue
        lines.append(
            ProductLine(
                "category",
                category,
                sum(p.quantity for p in products),
                0,
                sum(p.revenue_xof for p in products),
            )
        )
        for p in products:
            unit = round(p.revenue_xof / p.quantity) if p.quantity else 0
            lines.append(ProductLine("product", p.name, p.quantity, unit, p.revenue_xof))
    return lines


class _ReportPdf(FPDF):
    def __init__(self, day: date, stamp: tuple[str, tuple[int, int, int]], edited: str) -> None:
        super().__init__(orientation="P", unit="mm", format="A4")
        # Polices intégrées en Windows-1252 : accents, « œ », tirets et guillemets français
        self.core_fonts_encoding = "windows-1252"
        self.day = day
        self.stamp = stamp
        self.edited = edited
        self.set_margins(12, 12, 12)
        self.set_auto_page_break(auto=False)
        self.alias_nb_pages()

    def header(self) -> None:
        top = 12
        if LOGO_PATH.exists():
            self.image(str(LOGO_PATH), x=12, y=top, h=14)
        self.set_xy(32, top)
        self.set_text_color(*INK)
        self.set_font("Helvetica", "B", 13)
        self.cell(110, 6, "RAPPORT DE VENTES DE LA JOURNÉE")
        self.set_xy(32, top + 6)
        self.set_font("Helvetica", "B", 7.5)
        self.set_text_color(63, 63, 70)
        self.cell(110, 4, "MYK RESTAURANT • ABIDJAN")
        self.set_xy(32, top + 10)
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(*INK)
        self.cell(110, 4, format_day(self.day).capitalize())
        # Tampon de statut
        text, color = self.stamp
        self.set_font("Helvetica", "B", 6.5)
        w = self.get_string_width(text) + 5
        self.set_draw_color(*color)
        self.set_text_color(*color)
        self.set_xy(198 - w, top + 3)
        self.cell(w, 5, text, border=1, align="C")
        # Filet
        self.set_draw_color(*INK)
        self.set_line_width(0.6)
        self.line(12, top + 17, 198, top + 17)
        self.set_line_width(0.2)
        self.set_y(top + 20)

    def footer(self) -> None:
        self.set_draw_color(*LINE)
        self.line(12, 284, 198, 284)
        self.set_xy(12, 285)
        self.set_font("Helvetica", "", 6.5)
        self.set_text_color(*MUTED)
        self.cell(150, 4, f"Édité le {self.edited} — Rapport de gestion, ne remplace pas le rapport Z")
        self.set_font("Helvetica", "B", 6.5)
        self.cell(36, 4, f"Page {self.page_no()} / {{nb}}", align="R")

    # --- éléments ---------------------------------------------------------------------------

    def section_title(self, title: str, x: float = 12, w: float = 186) -> None:
        self.set_x(x)
        self.set_font("Helvetica", "B", 7.5)
        self.set_text_color(*INK)
        self.cell(w, 5, title.upper())
        y = self.get_y() + 5
        self.set_draw_color(*INK)
        self.line(x, y, x + w, y)
        self.set_y(y + 1)

    def kpi(self, x: float, y: float, w: float, label: str, value: str, sub: str) -> None:
        self.set_draw_color(*LINE)
        self.rect(x, y, w, 15)
        self.set_xy(x + 2, y + 1.2)
        self.set_font("Helvetica", "B", 5.5)
        self.set_text_color(*MUTED)
        self.cell(w - 4, 3, label.upper())
        self.set_xy(x + 2, y + 4.6)
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(*INK)
        self.cell(w - 4, 5, value)
        self.set_xy(x + 2, y + 10)
        self.set_font("Helvetica", "", 6)
        self.set_text_color(82, 82, 91)
        self.cell(w - 4, 3.5, sub)

    def simple_table(
        self,
        x: float,
        widths: list[float],
        headers: list[str],
        aligns: list[str],
        rows: list[list[str]],
        empty: str,
        bold_col: int,
    ) -> None:
        """Petit tableau : en-tête souligné, lignes séparées, colonne `bold_col` (montant) en gras."""
        self.set_x(x)
        self.set_font("Helvetica", "B", 6)
        self.set_text_color(*MUTED)
        for w, h, a in zip(widths, headers, aligns, strict=True):
            self.cell(w, 4.5, h.upper(), align=a)
        y = self.get_y() + 4.5
        self.set_draw_color(*INK)
        self.line(x, y, x + sum(widths), y)
        self.set_y(y)
        self.set_text_color(*INK)
        self.set_draw_color(*LINE)
        if not rows:
            rows = [[empty] + [""] * (len(widths) - 1)]
        for row in rows:
            self.set_x(x)
            for i, (w, value, a) in enumerate(zip(widths, row, aligns, strict=True)):
                self.set_font("Helvetica", "B" if i == bold_col else "", 7.5)
                self.cell(w, 4.8, value, align=a)
            y = self.get_y() + 4.8
            self.line(x, y, x + sum(widths), y)
            self.set_y(y)


PRODUCT_WIDTHS = [111.0, 20.0, 27.0, 28.0]
ROW_H = 4.8
PAGE_BOTTOM = 280.0


def _product_header(pdf: _ReportPdf) -> None:
    pdf.set_font("Helvetica", "B", 6)
    pdf.set_text_color(*MUTED)
    for w, h, a in zip(PRODUCT_WIDTHS, ["Produit", "Qté", "Prix moyen", "Montant"], "LRRR", strict=True):
        pdf.cell(w, 4.5, h.upper(), align=a)
    y = pdf.get_y() + 4.5
    pdf.set_draw_color(*INK)
    pdf.line(12, y, 198, y)
    pdf.set_xy(12, y)


def build_daily_report_pdf(
    day: date,
    overview: DashboardOut,
    sales: SalesReportOut,
    *,
    edited_at: datetime | None = None,
) -> bytes:
    """Produit le PDF A4 (une ou plusieurs feuilles) du rapport de ventes d'une journée."""
    edited = (edited_at or datetime.now(TZ)).astimezone(TZ)
    pdf = _ReportPdf(day, status_text(overview), f"{edited:%d/%m/%Y à %H:%M} (envoi automatique)")
    pdf.add_page()

    revenue = overview.revenue_xof
    total_qty = sum(p.quantity for p in sales.by_product)

    # Chiffres clés : deux rangées de quatre cadres
    pdf.section_title("Chiffres clés")
    y = pdf.get_y() + 1
    w = (186 - 3 * 2) / 4
    fne_sub = f"{overview.fne.pending} en attente" if overview.fne.pending else "Aucune en attente"
    kpis = [
        ("Chiffre d'affaires", format_xof(revenue), "TTC — Régime TEE (TVA 0 %)"),
        ("Additions encaissées", str(overview.orders_paid), f"{overview.orders_open} en cours"),
        ("Panier moyen", format_xof(overview.average_ticket_xof), "Par addition réglée"),
        ("Articles vendus", str(total_qty), f"{len(sales.by_product)} produits différents"),
        (
            "Sur place / emporter / livraison",
            f"{overview.dine_in_orders} / {overview.takeaway_orders} / {overview.delivery_orders}",
            "Additions encaissées",
        ),
        ("Annulations", str(overview.orders_cancelled), "Commandes annulées"),
        (
            "Factures FNE",
            f"{overview.fne.certified} certifiée{'s' if overview.fne.certified > 1 else ''}",
            fne_sub,
        ),
        (
            "Sessions de caisse",
            str(len(overview.sessions)),
            ", ".join(s.cash_register for s in overview.sessions) or "—",
        ),
    ]
    for i, (label, value, sub) in enumerate(kpis):
        pdf.kpi(12 + (i % 4) * (w + 2), y + (i // 4) * 17, w, label, value, sub)
    pdf.set_y(y + 36)

    # Encaissements et caissiers (gauche), ventes par heure (droite)
    top = pdf.get_y()
    left_w, right_x, right_w = 90.0, 108.0, 90.0
    pdf.section_title("Encaissements par moyen de paiement", 12, left_w)
    pdf.simple_table(
        12,
        [42, 12, 26, 10],
        ["Moyen", "Nb", "Montant", "%"],
        ["L", "R", "R", "R"],
        [
            [payment_label(p.method, p.provider), str(p.count), format_xof(p.amount_xof), pct(p.amount_xof, revenue)]
            for p in overview.payments
        ],
        "Aucun encaissement",
        bold_col=2,
    )
    pdf.set_y(pdf.get_y() + 3)
    pdf.section_title("Encaissements par caissier", 12, left_w)
    pdf.simple_table(
        12,
        [46, 18, 26],
        ["Caissier", "Additions", "Montant"],
        ["L", "R", "R"],
        [[c.full_name, str(c.orders_count), format_xof(c.revenue_xof)] for c in overview.by_cashier],
        "—",
        bold_col=2,
    )
    left_bottom = pdf.get_y()

    pdf.set_y(top)
    pdf.section_title("Ventes par heure", right_x, right_w)
    pdf.simple_table(
        right_x,
        [30, 18, 30, 12],
        ["Heure", "Additions", "Montant", "%"],
        ["L", "R", "R", "R"],
        [
            [
                f"{h.hour:02d} h – {h.hour + 1:02d} h",
                str(h.orders_count),
                format_xof(h.revenue_xof),
                pct(h.revenue_xof, revenue),
            ]
            for h in overview.hourly
        ],
        "—",
        bold_col=2,
    )
    pdf.set_y(max(left_bottom, pdf.get_y()) + 4)

    # Détail des produits vendus
    pdf.section_title("Détail des produits vendus")
    _product_header(pdf)
    lines = product_lines(sales)
    if not lines:
        pdf.set_font("Helvetica", "", 7.5)
        pdf.set_text_color(*INK)
        pdf.cell(186, ROW_H, "Aucune vente sur la journée")
        pdf.set_xy(12, pdf.get_y() + ROW_H)
    for line in lines:
        # Pas d'en-tête de catégorie seul en bas de feuille
        needed = ROW_H * (3 if line.kind == "category" else 1)
        if pdf.get_y() + needed > PAGE_BOTTOM:
            pdf.add_page()
            pdf.section_title("Détail des produits vendus (suite)")
            _product_header(pdf)
        y = pdf.get_y()
        is_cat = line.kind == "category"
        if is_cat:
            pdf.set_fill_color(*SHADE)
            pdf.rect(12, y, 186, ROW_H, style="F")
        pdf.set_text_color(*INK)
        pdf.set_font("Helvetica", "B" if is_cat else "", 6.5 if is_cat else 7.5)
        pdf.set_x(12)
        pdf.cell(PRODUCT_WIDTHS[0], ROW_H, line.label.upper() if is_cat else f"    {line.label}")
        pdf.set_font("Helvetica", "B" if is_cat else "", 7.5)
        pdf.cell(PRODUCT_WIDTHS[1], ROW_H, str(line.quantity), align="R")
        pdf.set_text_color(*(INK if is_cat else MUTED))
        pdf.cell(PRODUCT_WIDTHS[2], ROW_H, "" if is_cat else format_xof(line.unit_price_xof), align="R")
        pdf.set_text_color(*INK)
        pdf.set_font("Helvetica", "B", 7.5)
        pdf.cell(PRODUCT_WIDTHS[3], ROW_H, format_xof(line.revenue_xof), align="R")
        pdf.set_draw_color(*LINE)
        pdf.line(12, y + ROW_H, 198, y + ROW_H)
        pdf.set_xy(12, y + ROW_H)

    # Total général et signatures (sur une nouvelle feuille s'il ne reste pas la place)
    if pdf.get_y() + 38 > PAGE_BOTTOM:
        pdf.add_page()
    y = pdf.get_y()
    pdf.set_draw_color(*INK)
    pdf.set_line_width(0.6)
    pdf.line(12, y, 198, y)
    pdf.set_line_width(0.2)
    pdf.set_xy(12, y + 0.5)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.set_text_color(*INK)
    pdf.cell(PRODUCT_WIDTHS[0], 5.5, "TOTAL GÉNÉRAL")
    pdf.cell(PRODUCT_WIDTHS[1], 5.5, str(total_qty), align="R")
    pdf.cell(PRODUCT_WIDTHS[2], 5.5, "")
    pdf.cell(PRODUCT_WIDTHS[3], 5.5, format_xof(sales.totals.revenue_xof), align="R")

    y = pdf.get_y() + 12
    for i, who in enumerate(["LE CAISSIER", "LE RESPONSABLE"]):
        x = 12 + i * 98
        pdf.set_xy(x, y)
        pdf.set_font("Helvetica", "B", 6.5)
        pdf.set_text_color(63, 63, 70)
        pdf.cell(88, 4, who)
        pdf.set_draw_color(161, 161, 170)
        pdf.set_dash_pattern(dash=1, gap=1)
        pdf.rect(x, y + 5, 88, 14)
        pdf.set_dash_pattern()
        pdf.set_xy(x, y + 19.5)
        pdf.set_font("Helvetica", "", 6)
        pdf.set_text_color(*MUTED)
        pdf.cell(88, 3.5, "Nom, date et signature")

    return bytes(pdf.output())
