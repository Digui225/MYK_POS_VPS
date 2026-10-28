from decimal import Decimal, InvalidOperation
from typing import Any

from sqlalchemy.orm import Session

from caisse.models.settings import AppSetting


def get_value(db: Session, key: str, default: Any = None) -> Any:
    """Paramètre métier (table `settings`), ou `default` s'il n'a jamais été créé : une base
    amorcée avant l'ajout d'une clé continue de fonctionner sans relancer `bootstrap`."""
    setting = db.get(AppSetting, key)
    return default if setting is None else setting.value


def set_value(db: Session, key: str, value: Any, user_id: str | None = None) -> None:
    """Enregistre ou met à jour un paramètre métier dans la table `settings`."""
    setting = db.get(AppSetting, key)
    if setting is None:
        setting = AppSetting(key=key, value=value, updated_by=user_id)
        db.add(setting)
    else:
        setting.value = value
        setting.updated_by = user_id


# Régime TEE (confirmé pour Chez Sylla Plus) : pas de TVA (0%), code FNE TVAD
DEFAULT_VAT_RATE = Decimal("0.00")


def default_vat_rate(db: Session) -> Decimal:
    """Taux de TVA des nouveaux produits (`vat.default_rate`, en %)."""
    try:
        return Decimal(str(get_value(db, "vat.default_rate", DEFAULT_VAT_RATE)))
    except InvalidOperation:
        return DEFAULT_VAT_RATE
