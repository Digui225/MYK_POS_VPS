import argparse
import pytest
from unittest.mock import patch, MagicMock

from caisse.cli import cmd_reset_transactions
from caisse.config import Settings
from caisse.models.audit import AuditLog


def test_reset_transactions_forbidden_in_production():
    db = MagicMock()
    args = argparse.Namespace(yes=True)
    prod_settings = Settings(
        APP_ENV="production",
        DEBUG=False,
        JWT_SECRET="x" * 64,
    )

    with patch("caisse.cli.get_settings", return_value=prod_settings):
        with pytest.raises(SystemExit) as exc_info:
            cmd_reset_transactions(db, args)
        assert exc_info.value.code == 1
    # Aucun delete ne doit avoir été appelé
    db.query.assert_not_called()


def test_reset_transactions_allowed_in_dev_and_creates_audit_log():
    db = MagicMock()
    args = argparse.Namespace(yes=True)
    dev_settings = Settings(
        APP_ENV="development",
        DEBUG=True,
    )

    with patch("caisse.cli.get_settings", return_value=dev_settings):
        cmd_reset_transactions(db, args)

    # Vérifie qu'un AuditLog a été ajouté et db.commit() a été appelé
    assert db.add.called
    added_obj = db.add.call_args[0][0]
    assert isinstance(added_obj, AuditLog)
    assert added_obj.action == "RESET_TRANSACTIONS"
    assert db.commit.called
