import argparse
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

from agent.config import AgentSettings, get_settings
from agent.escpos_driver import EscposDriver
from agent.poller import Poller


def _setup_logging(settings: AgentSettings) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if settings.log_file:
        path = Path(settings.log_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(RotatingFileHandler(path, maxBytes=1_000_000, backupCount=5,
                                            encoding="utf-8"))
    # force : une dépendance (python-escpos) pose déjà un handler, qui rendrait l'appel inopérant
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=handlers, force=True)
    logging.getLogger("httpx").setLevel(logging.WARNING)  # une ligne par interrogation sinon


def main() -> None:
    parser = argparse.ArgumentParser(prog="agent")
    parser.add_argument("--list", action="store_true",
                        help="imprimantes Windows installées (valeur de PRINTER_NAME)")
    if parser.parse_args().list:
        from agent import win32_spool

        print("\n".join(win32_spool.list_printers()))
        return

    settings = get_settings()
    _setup_logging(settings)
    if not settings.terminal_token:
        raise SystemExit("TERMINAL_TOKEN est obligatoire (POST /api/v1/printing/terminals)")
    if settings.printer_backend == "win32" and not settings.printer_name:
        raise SystemExit("PRINTER_NAME est obligatoire avec win32 (python -m agent --list)")
    # un seul processus, un travail à la fois : l'imprimante n'est jamais sollicitée en parallèle
    Poller(settings, EscposDriver(settings)).run_forever()


if __name__ == "__main__":
    main()
