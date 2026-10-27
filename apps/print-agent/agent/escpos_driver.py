"""Pilote ESC/POS. Aucune règle métier : reçoit un texte déjà mis en forme par l'API.

Le périphérique est ouvert puis fermé à chaque job : un débranchement/rebranchement de
l'imprimante ne demande donc pas de redémarrer l'agent. Sous Windows (`win32`), les octets sont
construits en mémoire puis remis au spouleur (`win32_spool.py`).
"""

import logging
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

from escpos.escpos import Escpos
from escpos.printer import Dummy, Usb

from agent.config import AgentSettings

log = logging.getLogger("print-agent")


class PrinterUnavailable(Exception):
    pass


@dataclass
class Status:
    online: bool
    paper: str  # ok | near_end | empty | unknown
    model: str
    width: int


import unicodedata


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


def _load_logo_bytes() -> bytes | None:
    """Charge les octets de la séquence raster ESC/POS monochrome du logo Sylla Plus."""
    from pathlib import Path
    candidates = [
        Path(__file__).resolve().parent / "assets" / "sylla_logo_escpos.bin",
        Path(__file__).resolve().parent.parent.parent / "api" / "src" / "caisse" / "assets" / "sylla_logo_escpos.bin",
    ]
    for p in candidates:
        if p.exists():
            try:
                data = p.read_bytes()
                if data.endswith(b"\x1b2\n"):
                    data = data[:-1]
                return data
            except Exception:
                pass
    return None


class EscposDriver:
    def __init__(self, settings: AgentSettings) -> None:
        self.settings = settings
        self._lock = threading.Lock()  # un seul job à la fois sur le port USB

    @contextmanager
    def _printer(self) -> Iterator[Escpos]:
        s = self.settings
        if s.printer_backend == "dummy":
            dummy = Dummy()
            yield dummy
            log.info("[dummy] %d octets envoyés :\n%s", len(dummy.output),
                     dummy.output.decode("cp858", errors="replace"))
            return
        if s.printer_backend == "win32":
            from agent import win32_spool  # pywin32 : Windows seulement

            buffer = Dummy()
            yield buffer
            try:
                win32_spool.send_raw(s.printer_name, buffer.output,
                                     timeout=s.spool_timeout_seconds)
            except win32_spool.SpoolError as exc:
                raise PrinterUnavailable(str(exc)) from exc
            return
        try:
            printer = Usb(s.printer_vendor_id, s.printer_product_id, in_ep=s.printer_in_ep,
                          out_ep=s.printer_out_ep)
            printer.open()
        except Exception as exc:  # usb.core.USBError, DeviceNotFoundError…
            raise PrinterUnavailable(str(exc)) from exc
        try:
            yield printer
        finally:
            printer.close()

    def _setup(self, printer: Escpos) -> None:
        # 1. Reset initialisation
        try:
            printer._raw(b"\x1b\x40")
        except Exception:
            pass

        # 2. Annuler le mode caractères chinois (FS .) actif par défaut sur les Xprinter / POS-58
        try:
            printer._raw(b"\x1c\x2e")
        except Exception:
            pass

        # 3. Sélectionner la table de caractères standard PC437
        try:
            printer._raw(b"\x1b\x74\x00")
        except Exception:
            pass

        # 4. Configurer la page de codes occidentale
        try:
            printer.charcode(self.settings.printer_codepage)
        except Exception:
            log.warning("page de code %s non prise en charge", self.settings.printer_codepage)

    def status(self) -> Status:
        s = self.settings
        if s.printer_backend == "dummy":
            return Status(online=True, paper="ok", model="dummy", width=s.printer_width)
        if s.printer_backend == "win32":
            from agent import win32_spool

            try:
                online, paper = win32_spool.status(s.printer_name)
            except win32_spool.SpoolError:
                online, paper = False, "unknown"
            return Status(online=online, paper=paper, model=f"win32:{s.printer_name}",
                          width=s.printer_width)
        model = f"usb:{s.printer_vendor_id:04x}:{s.printer_product_id:04x}"
        with self._lock:
            try:
                with self._printer() as printer:
                    paper = _paper(printer)
                return Status(online=True, paper=paper, model=model, width=s.printer_width)
            except PrinterUnavailable:
                return Status(online=False, paper="unknown", model=model, width=s.printer_width)

    def print(self, content: str, *, qr: str | None = None, open_drawer: bool = False, cut: bool = True) -> None:
        import re
        with self._lock, self._printer() as printer:
            # le tiroir s'ouvre dans le même job que le ticket (exigence client)
            if open_drawer:
                printer._raw(self.settings.drawer_pulse_bytes)
            self._setup(printer)

            # Injection du Logo raster au début du ticket
            has_logo_tag = "[LOGO]" in content
            if has_logo_tag:
                content = content.replace("[LOGO]\n", "").replace("[LOGO]", "")

            logo_bytes = _load_logo_bytes()
            if logo_bytes and ("Sylla Plus" in content or "Ticket :" in content or "Abidjan Plateau" in content or has_logo_tag):
                try:
                    printer._raw(b"\x1b\x61\x01")  # centrer
                    printer._raw(logo_bytes)
                    printer._raw(b"\x1b\x61\x00")  # réaligner à gauche sans saut de ligne superflu
                except Exception as exc:
                    log.warning("échec d'envoi du logo raster : %s", exc)

                # Le logo contient déjà "Sylla Plus" en grand : supprimer la ligne texte en doublon
                content = re.sub(r"^\s*(?:RESTAURANT\s+)?SYLLA\s+PLUS\s*\n?", "", content, flags=re.MULTILINE | re.IGNORECASE)

            # Découpage si QR code FNE présent au milieu du ticket
            qr_match = re.search(r"\[QR_CODE:\s*([^\]]+)\]", content)
            if qr_match:
                extracted_qr = qr_match.group(1).strip()
                parts = re.split(r"\[QR_CODE:\s*[^\]]+\]", content, maxsplit=1)
                before_qr = sanitize_french_text(parts[0])
                after_qr = sanitize_french_text(parts[1] if len(parts) > 1 else "")

                printer.text(before_qr if before_qr.endswith("\n") else before_qr + "\n")
                try:
                    printer.qr(extracted_qr, size=4, center=True)
                except Exception as exc:
                    log.error("échec d'impression du QR code : %s", exc)
                if after_qr.strip():
                    printer.text(after_qr if after_qr.endswith("\n") else after_qr + "\n")
            else:
                cleaned_content = sanitize_french_text(content)
                printer.text(cleaned_content if cleaned_content.endswith("\n") else cleaned_content + "\n")
                if qr:
                    try:
                        printer.qr(qr, size=4, center=True)
                    except Exception as exc:
                        log.error("échec d'impression du QR code : %s", exc)

            if cut:
                printer.cut()

    def open_drawer(self) -> None:
        with self._lock, self._printer() as printer:
            printer._raw(self.settings.drawer_pulse_bytes)


def _paper(printer: Escpos) -> str:
    """Beaucoup d'imprimantes d'entrée de gamme ne répondent pas : on renvoie `unknown`."""
    try:
        return {2: "ok", 1: "near_end", 0: "empty"}.get(printer.paper_status(), "unknown")
    except Exception:
        return "unknown"
