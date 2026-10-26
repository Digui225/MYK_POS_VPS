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
        # 1. Annuler le mode caractères chinois (FS .) actif par défaut sur les Xprinter
        try:
            printer._raw(b"\x1c\x2e")
        except Exception:
            pass

        # 2. Configurer la page de codes occidentale
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

            # Découpage si QR code FNE présent au milieu du ticket
            qr_match = re.search(r"\[QR_CODE:\s*([^\]]+)\]", content)
            if qr_match:
                extracted_qr = qr_match.group(1).strip()
                parts = re.split(r"\[QR_CODE:\s*[^\]]+\]", content, maxsplit=1)
                before_qr = parts[0]
                after_qr = parts[1] if len(parts) > 1 else ""

                printer.text(before_qr if before_qr.endswith("\n") else before_qr + "\n")
                try:
                    printer.qr(extracted_qr, size=4, center=True)
                except Exception as exc:
                    log.error("échec d'impression du QR code : %s", exc)
                if after_qr.strip():
                    printer.text(after_qr if after_qr.endswith("\n") else after_qr + "\n")
            else:
                printer.text(content if content.endswith("\n") else content + "\n")
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
