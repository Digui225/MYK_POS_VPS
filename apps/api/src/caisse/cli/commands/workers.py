import argparse

from sqlalchemy.orm import Session

from caisse.infrastructure.outbox.worker import run_outbox_worker_sync
from caisse.services.print_terminal_service import PrintTerminalService


def cmd_outbox_worker(args: argparse.Namespace) -> None:
    run_outbox_worker_sync(once=args.once, interval_seconds=args.interval)


def cmd_create_print_terminal(db: Session, args: argparse.Namespace) -> None:
    term_service = PrintTerminalService(db)
    terminal, token = term_service.create_terminal(name=args.name)
    print(f" Terminal « {terminal.name} » créé. Jeton de l'agent (affiché une seule fois) :")
    print(token)
