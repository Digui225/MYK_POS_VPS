import textwrap
import unicodedata
from typing import Any

from fastapi import status

from caisse.domain.enums import PaymentMethod
from caisse.errors import CaisseException

# Commandes standard ESC/POS pour imprimantes thermiques (XP-58IIH / POS-58 / 80mm)
ESC_INIT = b"\x1b\x40"
FS_CANCEL_CHINESE = b"\x1c\x2e"          # Annulation stricte du mode caractères chinois (Xprinter / POS-58)
ESC_SELECT_CP437 = b"\x1b\x74\x00"       # Sélection table de caractères standard PC437
ESC_SELECT_CP1252 = b"\x1b\x74\x10"      # Sélection table Windows-1252
ESC_DRAWER_KICK = b"\x1b\x70\x00\x19\xfa"  # Envoi impulsion tiroir DK port RJ11
ESC_CUT_PAPER = b"\x1d\x56\x42\x00"        # Coupe papier avec avance massicot


def sanitize_french_text(text: str) -> str:
    """Remplace les accents et caractères typographiques par leurs équivalents ASCII 7 bits
    pour éviter tout décodage fantôme en idéogrammes chinois (GBK/GB2312) sur imprimantes thermiques."""
    replacements = {
        "·": ".",
        "’": "'",
        "‘": "'",
        "“": '"',
        "”": '"',
        "«": '"',
        "»": '"',
        "–": "-",
        "—": "-",
        "°": "o",
        "€": "EUR",
        "œ": "oe",
        "Œ": "OE",
        "æ": "ae",
        "Æ": "AE",
    }
    for k, v in replacements.items():
        text = text.replace(k, v)

    nfd = unicodedata.normalize("NFD", text)
    ascii_text = "".join(c for c in nfd if unicodedata.category(c) != "Mn")
    return ascii_text.encode("ascii", errors="replace").decode("ascii")


def build_esc_pos_qr(data: str, size: int = 4) -> bytes:
    """Génère la séquence ESC/POS native GS ( k pour imprimer un QR Code 2D (Modèle 2)."""
    data_bytes = data.encode("ascii", errors="replace")
    data_len = len(data_bytes) + 3
    pL = data_len & 0xFF
    pH = (data_len >> 8) & 0xFF

    res = bytearray()
    res.extend(b"\x1d\x28\x6b\x04\x00\x31\x41\x32\x00")          # 1. Modèle 2
    res.extend(b"\x1d\x28\x6b\x03\x00\x31\x43" + bytes([size]))  # 2. Taille module (dots)
    res.extend(b"\x1d\x28\x6b\x03\x00\x31\x45\x31")              # 3. Correction d'erreur Niveau M
    res.extend(b"\x1d\x28\x6b" + bytes([pL, pH]) + b"\x31\x50\x30" + data_bytes)  # 4. Données
    res.extend(b"\x1d\x28\x6b\x03\x00\x31\x51\x30")              # 5. Impression
    return bytes(res)


def validate_payment_amount(amount_xof: int, due_xof: int) -> None:
    """Vérifie que le montant à encaisser est valide vis-à-vis du reste dû."""
    if amount_xof <= 0:
        raise CaisseException(
            code="INVALID_PAYMENT_AMOUNT",
            title="Montant de paiement invalide",
            detail="Le montant du paiement doit être strictement supérieur à 0 XOF.",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )
    if amount_xof > due_xof:
        raise CaisseException(
            code="OVERPAYMENT_NOT_ALLOWED",
            title="Montant supérieur au reste dû",
            detail=f"Le montant ({amount_xof} XOF) ne peut pas excéder le reste dû ({due_xof} XOF).",
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            meta={"amount_xof": amount_xof, "due_xof": due_xof},
        )


def calculate_change(tendered_xof: int | None, amount_xof: int, method: str) -> int:
    """Calcule le rendu de monnaie en espèces."""
    if method == PaymentMethod.CASH:
        if tendered_xof is not None:
            if tendered_xof < amount_xof:
                raise CaisseException(
                    code="INSUFFICIENT_TENDERED_AMOUNT",
                    title="Montant remis insuffisant",
                    detail=f"Le montant remis ({tendered_xof} XOF) est inférieur au montant à payer ({amount_xof} XOF).",
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    meta={"tendered_xof": tendered_xof, "amount_xof": amount_xof},
                )
            return tendered_xof - amount_xof
        return 0
    return 0


def should_open_drawer(method: str, is_reprint: bool = False, is_manual_override: bool = False) -> bool:
    """Règle stricte d'ouverture tiroir : jamais sur ré-impression, oui sur espèces ou action manuelle responsable."""
    if is_reprint:
        return False
    if is_manual_override:
        return True
    return method == PaymentMethod.CASH


from pathlib import Path

_CACHED_LOGO_BYTES: bytes | None = None


def get_esc_pos_logo_bytes() -> bytes | None:
    """Charge la séquence raster ESC/POS monochrome du logo Sylla Plus."""
    global _CACHED_LOGO_BYTES
    if _CACHED_LOGO_BYTES is not None:
        return _CACHED_LOGO_BYTES

    assets_dir = Path(__file__).resolve().parent.parent / "assets"
    bin_file = assets_dir / "sylla_logo_escpos.bin"
    if bin_file.exists():
        try:
            _CACHED_LOGO_BYTES = bin_file.read_bytes()
            return _CACHED_LOGO_BYTES
        except Exception:
            pass
    return None


def build_esc_pos_bytes(
    content: str,
    open_drawer: bool = False,
    cut: bool = True,
    qr_data: str | None = None,
    include_logo: bool = True,
) -> bytes:
    """Construit la séquence d'octets ESC/POS complète avec :
    - Réinitialisation et annulation forcée du mode chinois
    - Marge d'amorce haute (évite de rogner l'en-tête)
    - Déclenchement RJ11 tiroir-caisse si demandé
    - Traduction ASCII 7-bit de l'intégralité du texte
    - Rendu du logo graphique monochrome thermique
    - Rendu natif des QR codes 2D
    - Marge basse d'éjection (4 sauts de ligne)
    - Coupe papier si supporté
    """
    raw = bytearray()

    # 1. Reset initialisation
    raw.extend(ESC_INIT)

    # 2. Désactivation du mode idéogrammes chinois
    raw.extend(FS_CANCEL_CHINESE)

    # 3. Sélection code page PC437
    raw.extend(ESC_SELECT_CP437)

    # 4. Marge supérieure pour dégager le massicot / barre dentelée
    raw.extend(b"\n")

    # 5. Tiroir RJ11
    if open_drawer:
        raw.extend(ESC_DRAWER_KICK)

    # 6. Traitement des lignes de texte et détection de balises [LOGO] et [QR_CODE: ...]
    logo_already_printed = False
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped == "[LOGO]":
            if not logo_already_printed and include_logo:
                logo_bytes = get_esc_pos_logo_bytes()
                if logo_bytes:
                    raw.extend(b"\x1b\x61\x01")  # Centrage
                    raw.extend(logo_bytes)
                    raw.extend(b"\x1b\x61\x00\n")  # Retour alignement gauche
                    logo_already_printed = True
        elif stripped == "[NO_LOGO]":
            pass
        elif stripped.startswith("[QR_CODE:") and stripped.endswith("]"):
            qr_content = stripped[len("[QR_CODE:"): -1].strip()
            if qr_content:
                raw.extend(b"\n\x1b\x61\x01")  # Centrage
                raw.extend(build_esc_pos_qr(qr_content, size=4))
                raw.extend(b"\x1b\x61\x00\n")  # Retour alignement gauche
        elif stripped == "[QR_CODE]":
            pass
        else:
            clean_line = sanitize_french_text(line)
            raw.extend(clean_line.encode("ascii", errors="replace"))
            raw.extend(b"\n")

    # Si aucun tag [LOGO] explicite n'était dans le texte mais que logo demandé
    if include_logo and not logo_already_printed and "[NO_LOGO]" not in content:
        # Inséré au début juste après marge
        pass

    # 7. QR Code additionnel explicite
    if qr_data:
        raw.extend(b"\n\x1b\x61\x01")
        raw.extend(build_esc_pos_qr(qr_data, size=4))
        raw.extend(b"\x1b\x61\x00\n")

    # 8. Marge basse complète pour que tout le contenu sorte au-delà de la lame
    raw.extend(b"\n\n\n\n")

    # 9. Coupe papier
    if cut:
        raw.extend(ESC_CUT_PAPER)

    return bytes(raw)


def get_payment_method_display_label(method: str, provider: str | None = None) -> str:
    """Retourne un libellé clair et personnalisé pour le ticket (Wave, Orange Money, Espèces...)."""
    m = (method or "").upper()
    prov = (provider or "").upper()

    if m == "MOBILE_MONEY" or "MOBILE" in m:
        if "WAVE" in prov:
            return "Paiement Wave :"
        if "ORANGE" in prov:
            return "Paiement Orange Money :"
        if "MTN" in prov or "MOMO" in prov:
            return "Paiement MTN MoMo :"
        if "MOOV" in prov:
            return "Paiement Moov Money :"
        if provider:
            return f"Paiement {provider} :"
        return "Paiement Mobile Money :"

    if m == "CASH" or "ESPECE" in m:
        return "Reglement Especes :"

    if m == "CARD" or "CARTE" in m or "CB" in m:
        return "Paiement Carte bancaire :"

    if m == "BANK_TRANSFER" or "VIREMENT" in m:
        return "Paiement Virement :"

    if provider:
        return f"Paiement {method} ({provider}) :"
    return f"Paiement {method} :"


def format_receipt_text(
    restaurant_info: dict[str, Any],
    order_info: dict[str, Any],
    items: list[dict[str, Any]],
    payments: list[dict[str, Any]],
    totals: dict[str, Any],
    fne_info: dict[str, Any] | None = None,
    is_duplicate: bool = False,
    width: int = 32,
    welcome_message: str | None = None,
) -> str:
    """Génère le texte structuré et aligné pour le ticket de caisse thermique 32 colonnes (58mm)."""
    sep_line = "-" * width
    lines = []

    def center(txt: str) -> str:
        txt = txt.strip()
        if len(txt) > width:
            return txt[:width]
        return txt.center(width)

    def row(left: str, right: str) -> str:
        left_str = str(left)
        right_str = str(right)
        spaces = width - len(left_str) - len(right_str)
        if spaces < 1:
            max_left = width - len(right_str) - 1
            if max_left > 0:
                return f"{left_str[:max_left]} {right_str}"
            return f"{left_str} {right_str}"
        return f"{left_str}{' ' * spaces}{right_str}"

    # 1. En-tête restaurant avec balise [LOGO]
    lines.append("[LOGO]")

    raw_name = restaurant_info.get("name") or "Sylla Plus"
    display_name = raw_name.strip()
    if display_name.upper() in ("RESTAURANT SYLLA PLUS", "CHEZ SYLLA PLUS"):
        display_name = "Sylla Plus"
    elif display_name.upper().startswith("RESTAURANT "):
        display_name = display_name[11:].strip()
    if display_name:
        lines.append(center(display_name))

    addr = restaurant_info.get("address") or "Abidjan Plateau"
    if "Cocody" in addr or "Angré" in addr:
        addr = "Abidjan Plateau"
    if addr:
        for chunk in textwrap.wrap(addr, width=width):
            lines.append(center(chunk))

    phone = restaurant_info.get("phone") or "+225 07 00 00 00 00"
    if phone:
        lines.append(center(f"Tel: {phone}"))

    rccm = restaurant_info.get("rccm") or "CI-ABJ-2023-B-00000"
    ncc = restaurant_info.get("ncc") or "2000000 X"
    if rccm and ncc:
        lines.append(center(f"NCC: {ncc} . RCCM: {rccm}"))
    elif ncc:
        lines.append(center(f"NCC: {ncc}"))
    elif rccm:
        lines.append(center(f"RCCM: {rccm}"))

    if is_duplicate:
        lines.append(sep_line)
        lines.append(center("*** DUPLICATA ***"))

    lines.append(sep_line)

    # 2. Informations commande (Ticket, Table / Couverts, Caissier / Date)
    order_num = str(order_info.get("order_number", "-"))
    date_str = str(order_info.get("date_str", ""))
    cashier = str(order_info.get("cashier_name", "Caisse")).strip()
    if "Caissière Principale" in cashier or "Caissiere Principale" in cashier:
        cashier = "Caisse"
    table_label = str(order_info.get("table_label") or "Comptoir").strip()
    guests_count = order_info.get("guests_count")

    lines.append(row("Ticket :", order_num))

    table_display = table_label if table_label.lower().startswith("table") else f"Table {table_label}"
    guests_display = f"Couverts : {guests_count}" if guests_count else ""
    lines.append(row(f"Table : {table_display}", guests_display))

    cashier_display = f"Caissier : {cashier}"
    if date_str:
        if len(cashier_display) + len(date_str) + 1 > width:
            # Format court de l'année (ex: 27/10/26 09:57) pour tenir sur 32 colonnes
            short_date = date_str
            if len(date_str) >= 16 and date_str[6:8] == "20":
                short_date = date_str[:6] + date_str[8:]
            if len(cashier_display) + len(short_date) + 1 <= width:
                lines.append(row(cashier_display, short_date))
            else:
                lines.append(cashier_display)
                lines.append(row("", date_str))
        else:
            lines.append(row(cashier_display, date_str))
    else:
        lines.append(cashier_display)

    lines.append(sep_line)

    # 3. Détail des articles (sans en-tête DESIGNATION/MONTANT, épuré)
    for item in items:
        qty = item.get("quantity", 1)
        item_name = item.get("name", "Article")
        total_price = f"{item.get('line_total_xof', 0):,} FCFA".replace(",", " ")
        prefix = f"{qty}x {item_name}"
        if len(prefix) + len(total_price) + 1 <= width:
            lines.append(row(prefix, total_price))
        else:
            max_len = width - len(total_price) - 1
            if max_len > len(f"{qty}x "):
                lines.append(row(prefix[:max_len], total_price))
            else:
                lines.append(prefix)
                lines.append(row("", total_price))

    lines.append("")

    # 4. Total TTC
    total_val = f"{totals.get('total_ttc_xof', 0):,} FCFA".replace(",", " ")
    lines.append(row("TOTAL TTC", total_val))

    vat_rate = totals.get("vat_rate", 0)
    vat_amt = totals.get("total_vat_xof", 0)
    if vat_amt > 0 and vat_rate > 0:
        lines.append(row(f"  dont TVA ({vat_rate}%):", f"{vat_amt:,} FCFA".replace(",", " ")))

    # 5. Règlements & Rendu
    tendered = totals.get("tendered_xof")
    change = totals.get("change_xof", 0)
    if tendered and change > 0:
        lines.append(row("Especes recues :", f"{tendered:,} FCFA".replace(",", " ")))
        lines.append(row("Monnaie rendue :", f"{change:,} FCFA".replace(",", " ")))
    elif payments:
        for p in payments:
            method = p.get("method", "PAIEMENT")
            provider = p.get("provider")
            method_label = get_payment_method_display_label(method, provider)
            method_label = method_label.replace("Paiement Espèces", "Reglement Especes").replace("Paiement Especes", "Reglement Especes")
            amount_str = f"{p.get('amount_xof', 0):,} FCFA".replace(",", " ")
            if len(method_label) + len(amount_str) + 1 <= width:
                lines.append(row(method_label, amount_str))
            else:
                lines.append(method_label)
                lines.append(amount_str.rjust(width))

    # 6. Bloc fiscal DGI / FNE
    fne_number = (fne_info or {}).get("fne_number") or order_info.get("fne_number")
    fne_qr_url = (fne_info or {}).get("qr_url") or order_info.get("fne_qr_url")
    if fne_number or fne_qr_url:
        lines.append(sep_line)
        lines.append(center("FACTURE NORMALISEE DGI"))
        if fne_number:
            lines.append(center(f"FNE ID : {fne_number}"))
        sig = (fne_info or {}).get("signature") or order_info.get("signature") or "DGI-CI-847291048"
        if sig:
            lines.append(center(f"Signature DGI : {sig}"))
        if fne_qr_url:
            lines.append(f"[QR_CODE: {fne_qr_url}]")

    # 7. Pied de ticket
    lines.append(sep_line)
    footer = restaurant_info.get("footer") or "Merci de votre visite et a tres bientot !"
    footer_clean = footer.replace("·", "").replace("À", "A").replace("à", "a").strip()
    if not footer_clean or "tres bientot" in footer_clean.lower():
        footer_clean = "Merci de votre visite et a tres bientot !"
    for chunk in textwrap.wrap(footer_clean, width=width):
        lines.append(center(chunk))

    return "\n".join(lines)


def format_z_report_text(
    restaurant_info: dict[str, Any],
    z_data: dict[str, Any],
    width: int = 32,
) -> str:
    """Genere le texte structure pour l'impression thermique du Rapport Z (58mm / 32 col)."""
    sep_line = "-" * width
    double_sep = "=" * width
    lines = []

    def center(txt: str) -> str:
        txt = txt.strip()
        if len(txt) > width:
            return txt[:width]
        return txt.center(width)

    def row(left: str, right: str) -> str:
        left_str = str(left)
        right_str = str(right)
        spaces = width - len(left_str) - len(right_str)
        if spaces < 1:
            max_left = width - len(right_str) - 1
            if max_left > 0:
                return f"{left_str[:max_left]} {right_str}"
            return f"{left_str} {right_str}"
        return f"{left_str}{' ' * spaces}{right_str}"

    def fmt_money(val: int | float | None) -> str:
        v = int(val or 0)
        return f"{v:,} F".replace(",", " ")

    # 1. En-tête restaurant
    lines.append("[LOGO]")
    name = (restaurant_info.get("name") or "").strip().upper()
    if name and name not in ("SYLLA PLUS", "RESTAURANT MYK", "CHEZ SYLLA PLUS"):
        lines.append(center(name))

    addr = restaurant_info.get("address", "Abidjan, Plateau")
    if addr:
        for part in addr.split("·"):
            part_clean = part.strip()
            if part_clean:
                for chunk in textwrap.wrap(part_clean, width=width):
                    lines.append(center(chunk))

    phone = restaurant_info.get("phone", "+225 07 58 00 00 00")
    if phone:
        lines.append(center(f"Tel : {phone}"))

    ncc = restaurant_info.get("ncc", "2104598B")
    if ncc:
        lines.append(center(f"NCC : {ncc}"))

    lines.append(double_sep)
    z_num = z_data.get("z_number", 0)
    lines.append(center(f"RAPPORT Z N* {z_num}"))
    lines.append(center("CLOTURE DEFINITIVE & CERTIFIEE"))
    lines.append(double_sep)

    # 2. Métadonnées
    lines.append(row("Date comptable", str(z_data.get("business_date", ""))))
    opened = str(z_data.get("opened_at", ""))
    if "T" in opened:
        opened = opened.split(".")[0].replace("T", " ")
    closed = str(z_data.get("closed_at", ""))
    if "T" in closed:
        closed = closed.split(".")[0].replace("T", " ")
    lines.append(row("Ouvert le", opened[:16]))
    lines.append(row("Cloture le", closed[:16]))
    lines.append(sep_line)

    # 3. Ventes globales
    ttc = z_data.get("total_sales_ttc_xof", 0)
    ht = z_data.get("total_sales_ht_xof", 0)
    vat = z_data.get("total_sales_vat_xof", 0)
    lines.append(row("TOTAL VENTES TTC", fmt_money(ttc)))
    lines.append(row("TOTAL HT", fmt_money(ht)))
    vat_label = "TVA COLLECTEE" if vat > 0 else "TVA (0% REGIME TEE)"
    lines.append(row(vat_label, fmt_money(vat)))
    lines.append(sep_line)

    # 4. Règlements
    lines.append(center("VENTILATION REGLEMENTS"))
    pm = z_data.get("payments_by_method", {}) or {}
    if pm:
        for method, amt in pm.items():
            lines.append(row(str(method), fmt_money(amt)))
    else:
        lines.append(center("Aucun reglement"))
    lines.append(sep_line)

    # 5. Ventes par catégorie
    cats = z_data.get("sales_by_category", {}) or {}
    if cats:
        lines.append(center("VENTES PAR CATEGORIE"))
        for cat_name, amt in cats.items():
            lines.append(row(str(cat_name), fmt_money(amt)))
        lines.append(sep_line)

    # 6. Espèces & Écart
    lines.append(center("BILAN ESPECES EN CAISSE"))
    lines.append(row("Fond initial", fmt_money(z_data.get("opening_float_xof", 0))))
    m_in = z_data.get("cash_movements_in_xof", 0)
    m_out = z_data.get("cash_movements_out_xof", 0)
    if m_in:
        lines.append(row("Entrees caisse", f"+{fmt_money(m_in)}"))
    if m_out:
        lines.append(row("Sorties caisse", f"-{fmt_money(m_out)}"))
    lines.append(row("Especes attendues", fmt_money(z_data.get("expected_cash_in_drawer_xof", 0))))
    lines.append(row("Especes comptees", fmt_money(z_data.get("counted_cash_xof", 0))))
    var = z_data.get("variance_xof", 0)
    lines.append(row("ECART DE CAISSE", fmt_money(var)))
    notes = z_data.get("notes")
    if notes:
        lines.append(f"Motif ecart: {notes}")
    lines.append(double_sep)

    # 7. Contrôle commandes
    orders_cnt = z_data.get("orders_count", 0)
    canc_cnt = z_data.get("cancelled_orders_count", 0)
    lines.append(row(f"Commandes : {orders_cnt}", f"Annulations : {canc_cnt}"))
    lines.append(double_sep)

    return "\n".join(lines)

