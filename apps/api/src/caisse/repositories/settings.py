from decimal import Decimal, InvalidOperation
from typing import Any

from sqlalchemy.orm import Session

from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.settings import AppSetting, EstablishmentSetting


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


def get_or_create_establishment_setting(db: Session) -> EstablishmentSetting:
    setting = db.query(EstablishmentSetting).first()
    if not setting:
        setting = EstablishmentSetting(
            restaurant_name="Restaurant MYK",
            ncc="1234567A",
            rccm="CI-ABJ-2026-B-0000",
            address="Abidjan, Côte d'Ivoire",
            phone="+225 0102030405",
            default_vat_rate=0.0,
            receipt_footer="Merci de votre visite et à très bientôt !",
            print_width=48,
            screen_lock_timeout_seconds=120,
        )
        db.add(setting)
        db.commit()
        db.refresh(setting)
    return setting


def list_registers(db: Session) -> list[CashRegister]:
    registers = db.query(CashRegister).order_by(CashRegister.created_at.asc()).all()
    if not registers:
        default_reg = CashRegister(
            id="0192384a-3000-7000-8000-000000000001",
            name="Caisse Principale",
            is_active=True,
        )
        db.add(default_reg)
        db.commit()
        db.refresh(default_reg)
        registers = [default_reg]
    return registers


def get_register(db: Session, register_id: str) -> CashRegister | None:
    return db.query(CashRegister).filter(CashRegister.id == register_id).first()


def get_register_by_name(db: Session, name: str) -> CashRegister | None:
    return db.query(CashRegister).filter(CashRegister.name == name).first()


def create_register(db: Session, name: str) -> CashRegister:
    reg = CashRegister(name=name, is_active=True)
    db.add(reg)
    db.commit()
    db.refresh(reg)
    return reg


def list_open_sessions(db: Session) -> list[CashSession]:
    return db.query(CashSession).filter(CashSession.status == "OPEN").all()


def get_open_session_for_register(db: Session, register_id: str) -> CashSession | None:
    return (
        db.query(CashSession)
        .filter(CashSession.cash_register_id == register_id, CashSession.status == "OPEN")
        .first()
    )
