"""Impression brute par le spouleur Windows (pywin32), avec le pilote du fabricant en place.

Les octets ESC/POS sont envoyés en `RAW` : le pilote Xprinter ne fait que les transmettre au
port USB, sans rendu. Pas de libusb/Zadig, qui priveraient Windows de l'imprimante.

Un travail accepté par le spouleur n'est pas encore imprimé : imprimante éteinte, il attend
dans la file Windows et sortirait des heures plus tard. On attend donc qu'il quitte la file ;
en cas d'erreur ou de délai dépassé, il est **supprimé** de la file Windows avant de signaler
l'échec, pour qu'un rejeu depuis la caisse ne donne jamais deux tickets.
"""

import time

import pywintypes
import win32print

# winspool.h — PRINTER_INFO_2.Status / Attributes, JOB_INFO_1.Status
PRINTER_ATTRIBUTE_WORK_OFFLINE = 0x400  # « Utiliser l'imprimante hors connexion » : file retenue
# Seuls les problèmes physiques que le pilote signale explicitement : OFFLINE / ERROR restent
# parfois affichés à tort par les pilotes USB, et la caisse ne confierait alors plus rien.
# Une vraie panne se voit de toute façon sur le travail lui-même (`_wait_printed`).
PRINTER_STATUS_PROBLEM = (
    0x8  # PAPER_JAM
    | 0x10  # PAPER_OUT
    | 0x40  # PAPER_PROBLEM
    | 0x400000  # DOOR_OPEN
)
PRINTER_STATUS_PAPER_OUT = 0x10
JOB_STATUS_PROBLEM = (
    0x2  # ERROR
    | 0x20  # OFFLINE
    | 0x40  # PAPEROUT
    | 0x200  # BLOCKED_DEVQ
    | 0x400  # USER_INTERVENTION
)
JOB_STATUS_DONE = 0x80 | 0x1000  # PRINTED | COMPLETE
JOB_CONTROL_DELETE = 5

_POLL_SECONDS = 0.2


class SpoolError(Exception):
    pass


def list_printers() -> list[str]:
    flags = win32print.PRINTER_ENUM_LOCAL | win32print.PRINTER_ENUM_CONNECTIONS
    return [entry[2] for entry in win32print.EnumPrinters(flags, None, 1)]


def _open(printer_name: str) -> int:
    try:
        return win32print.OpenPrinter(printer_name)
    except pywintypes.error as exc:
        raise SpoolError(f"imprimante Windows « {printer_name} » introuvable ({exc})") from exc


def status(printer_name: str) -> tuple[bool, str]:
    """(en ligne, papier). Le papier n'est connu que si le pilote le remonte."""
    handle = _open(printer_name)
    try:
        info = win32print.GetPrinter(handle, 2)
    finally:
        win32print.ClosePrinter(handle)
    printer_status, attributes = info["Status"], info["Attributes"]
    online = not (attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE) and not (
        printer_status & PRINTER_STATUS_PROBLEM
    )
    paper = "empty" if printer_status & PRINTER_STATUS_PAPER_OUT else "unknown"
    return online, paper


def _delete(handle: int, job_id: int) -> None:
    try:
        win32print.SetJob(handle, job_id, 0, None, JOB_CONTROL_DELETE)
    except pywintypes.error:
        pass  # déjà sorti de la file entre-temps


def _wait_printed(handle: int, job_id: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            job_status = win32print.GetJob(handle, job_id, 1)["Status"]
        except pywintypes.error:
            return  # sorti de la file : transmis à l'imprimante
        if job_status & JOB_STATUS_DONE:
            return
        if job_status & JOB_STATUS_PROBLEM:
            _delete(handle, job_id)
            raise SpoolError(f"travail Windows en erreur (état 0x{job_status:x}), supprimé")
        if time.monotonic() > deadline:
            _delete(handle, job_id)
            raise SpoolError(f"toujours dans la file Windows après {timeout:.0f} s, supprimé")
        time.sleep(_POLL_SECONDS)


def send_raw(printer_name: str, data: bytes, *, timeout: float) -> None:
    handle = _open(printer_name)
    try:
        try:
            job_id = win32print.StartDocPrinter(handle, 1, ("Caisse MYK", None, "RAW"))
        except pywintypes.error as exc:
            raise SpoolError(f"le spouleur refuse le travail ({exc})") from exc
        try:
            win32print.StartPagePrinter(handle)
            win32print.WritePrinter(handle, data)
            win32print.EndPagePrinter(handle)
        except pywintypes.error as exc:
            win32print.EndDocPrinter(handle)
            _delete(handle, job_id)
            raise SpoolError(f"écriture refusée par le spouleur ({exc})") from exc
        win32print.EndDocPrinter(handle)
        _wait_printed(handle, job_id, timeout)
    finally:
        win32print.ClosePrinter(handle)
