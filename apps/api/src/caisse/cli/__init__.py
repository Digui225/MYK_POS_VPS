"""Module CLI d'administration de la Caisse MYK."""

import signal

from caisse.cli.commands.catalog import (
    cmd_import_catalog,
    cmd_import_stock,
    cmd_set_vat_rate,
)
from caisse.cli.commands.db import (
    cmd_create_tables,
    cmd_reset_transactions,
    cmd_seed,
    cmd_seed_weekly_flow,
)
from caisse.cli.commands.fne import cmd_fne_probe, cmd_fne_worker
from caisse.cli.commands.users import cmd_create_user, cmd_reset_pin
from caisse.cli.commands.workers import cmd_create_print_terminal, cmd_outbox_worker
from caisse.cli.main import build_parser, main
from caisse.core.config import get_settings
from caisse.core.database import SessionLocal
from caisse.core.deps import get_fne_provider

__all__ = [
    "SessionLocal",
    "build_parser",
    "cmd_create_print_terminal",
    "cmd_create_tables",
    "cmd_create_user",
    "cmd_fne_probe",
    "cmd_fne_worker",
    "cmd_import_catalog",
    "cmd_import_stock",
    "cmd_outbox_worker",
    "cmd_reset_pin",
    "cmd_reset_transactions",
    "cmd_seed",
    "cmd_seed_weekly_flow",
    "cmd_set_vat_rate",
    "get_fne_provider",
    "get_settings",
    "main",
    "signal",
]
