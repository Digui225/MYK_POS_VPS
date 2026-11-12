"""Service métier pour la gestion des paramètres de l'établissement et des postes de caisse."""

from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.core.errors import CaisseException
from caisse.models.user import User
from caisse.repositories import settings as settings_repo
from caisse.schemas.settings import (
    CashRegisterResponse,
    CreateCashRegisterRequest,
    EstablishmentSettingsResponse,
    UpdateCashRegisterRequest,
    UpdateEstablishmentSettingsRequest,
)
from caisse.services import daily_report_mail_service


def get_establishment_settings(db: Session) -> EstablishmentSettingsResponse:
    """Récupère les paramètres de l'établissement complétés par la configuration FNE."""
    setting = settings_repo.get_or_create_establishment_setting(db)
    settings_cfg = get_settings()
    pos = str(settings_repo.get_value(db, "fne.point_of_sale", settings_cfg.FNE_POINT_OF_SALE) or "").strip()
    if pos == "CAISSE-1" and "services.fne.dgi.gouv.ci" in settings_cfg.FNE_API_BASE_URL:
        pos = "point de vente 1"
    estab = str(settings_repo.get_value(db, "fne.establishment", settings_cfg.FNE_ESTABLISHMENT) or "").strip()

    resp = EstablishmentSettingsResponse.model_validate(setting)
    resp.fne_point_of_sale = pos
    resp.fne_establishment = estab
    resp.report_email_recipients = daily_report_mail_service.get_recipients(db)
    resp.report_email_enabled = settings_cfg.mail_enabled
    return resp


def update_establishment_settings(
    db: Session,
    payload: UpdateEstablishmentSettingsRequest,
    *,
    admin: User,
) -> EstablishmentSettingsResponse:
    """Met à jour les paramètres de l'établissement et les clés FNE associées."""
    setting = settings_repo.get_or_create_establishment_setting(db)

    if payload.restaurant_name is not None:
        setting.restaurant_name = payload.restaurant_name.strip()
    if payload.ncc is not None:
        setting.ncc = payload.ncc.strip().upper()
    if payload.rccm is not None:
        setting.rccm = payload.rccm.strip().upper()
    if payload.address is not None:
        setting.address = payload.address.strip()
    if payload.phone is not None:
        setting.phone = payload.phone.strip()
    if payload.default_vat_rate is not None:
        setting.default_vat_rate = payload.default_vat_rate
    if payload.receipt_footer is not None:
        setting.receipt_footer = payload.receipt_footer.strip()
    if payload.print_width is not None:
        setting.print_width = payload.print_width

    if payload.fne_point_of_sale is not None:
        settings_repo.set_value(db, "fne.point_of_sale", payload.fne_point_of_sale.strip(), user_id=admin.id)
    if payload.fne_establishment is not None:
        settings_repo.set_value(db, "fne.establishment", payload.fne_establishment.strip(), user_id=admin.id)
    if payload.report_email_recipients is not None:
        daily_report_mail_service.set_recipients(db, payload.report_email_recipients, user_id=admin.id)

    db.commit()
    db.refresh(setting)

    settings_cfg = get_settings()
    pos = str(settings_repo.get_value(db, "fne.point_of_sale", settings_cfg.FNE_POINT_OF_SALE) or "").strip()
    estab = str(settings_repo.get_value(db, "fne.establishment", settings_cfg.FNE_ESTABLISHMENT) or "").strip()

    resp = EstablishmentSettingsResponse.model_validate(setting)
    resp.fne_point_of_sale = pos
    resp.fne_establishment = estab
    resp.report_email_recipients = daily_report_mail_service.get_recipients(db)
    resp.report_email_enabled = settings_cfg.mail_enabled
    return resp


def list_cash_registers(db: Session) -> list[CashRegisterResponse]:
    """Liste tous les postes de caisse avec l'état de leur session éventuelle."""
    registers = settings_repo.list_registers(db)
    open_sessions = settings_repo.list_open_sessions(db)
    open_session_by_reg = {s.cash_register_id: s for s in open_sessions}

    results: list[CashRegisterResponse] = []
    for r in registers:
        active_session = open_session_by_reg.get(r.id)
        results.append(
            CashRegisterResponse(
                id=r.id,
                name=r.name,
                is_active=r.is_active,
                has_active_session=bool(active_session),
                active_session_user=active_session.opened_by.full_name if active_session and active_session.opened_by else None,
                active_session_opened_at=active_session.opened_at.isoformat() if active_session and active_session.opened_at else None,
            )
        )
    return results


def create_cash_register(db: Session, payload: CreateCashRegisterRequest) -> CashRegisterResponse:
    """Crée un nouveau poste de caisse actif."""
    name = payload.name.strip()
    existing = settings_repo.get_register_by_name(db, name)
    if existing:
        raise CaisseException(
            code="REGISTER_ALREADY_EXISTS",
            title="Poste de caisse déjà existant",
            detail=f"Une caisse nommée '{name}' existe déjà.",
            status_code=status.HTTP_409_CONFLICT,
        )

    reg = settings_repo.create_register(db, name)
    return CashRegisterResponse(
        id=reg.id,
        name=reg.name,
        is_active=reg.is_active,
        has_active_session=False,
    )


def update_cash_register(
    db: Session,
    register_id: str,
    payload: UpdateCashRegisterRequest,
) -> CashRegisterResponse:
    """Met à jour le nom ou le statut actif d'une caisse (avec contrôle des sessions ouvertes)."""
    reg = settings_repo.get_register(db, register_id)
    if not reg:
        raise CaisseException(
            code="REGISTER_NOT_FOUND",
            title="Poste de caisse introuvable",
            detail=f"Aucune caisse avec l'identifiant '{register_id}' n'a été trouvée.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    if payload.name is not None and payload.name.strip() != reg.name:
        existing = settings_repo.get_register_by_name(db, payload.name.strip())
        if existing and existing.id != reg.id:
            raise CaisseException(
                code="REGISTER_ALREADY_EXISTS",
                title="Nom déjà utilisé",
                detail=f"Une caisse nommée '{payload.name.strip()}' existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )
        reg.name = payload.name.strip()

    if payload.is_active is not None and payload.is_active != reg.is_active:
        if not payload.is_active:
            open_session = settings_repo.get_open_session_for_register(db, reg.id)
            if open_session:
                raise CaisseException(
                    code="REGISTER_HAS_OPEN_SESSION",
                    title="Session de caisse en cours",
                    detail=f"Impossible de désactiver la caisse '{reg.name}' car une session de caisse y est actuellement ouverte.",
                    status_code=status.HTTP_409_CONFLICT,
                )
        reg.is_active = payload.is_active

    db.commit()
    db.refresh(reg)

    active_session = settings_repo.get_open_session_for_register(db, reg.id)
    return CashRegisterResponse(
        id=reg.id,
        name=reg.name,
        is_active=reg.is_active,
        has_active_session=bool(active_session),
        active_session_user=active_session.opened_by.full_name if active_session and active_session.opened_by else None,
        active_session_opened_at=active_session.opened_at.isoformat() if active_session and active_session.opened_at else None,
    )


def delete_cash_register(db: Session, register_id: str) -> str:
    """Désactive un poste de caisse après vérification qu'aucune session n'est ouverte."""
    reg = settings_repo.get_register(db, register_id)
    if not reg:
        raise CaisseException(
            code="REGISTER_NOT_FOUND",
            title="Poste de caisse introuvable",
            detail=f"Aucune caisse avec l'identifiant '{register_id}' n'a été trouvée.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    open_session = settings_repo.get_open_session_for_register(db, reg.id)
    if open_session:
        raise CaisseException(
            code="REGISTER_HAS_OPEN_SESSION",
            title="Session de caisse en cours",
            detail=f"Impossible de supprimer ou désactiver la caisse '{reg.name}' car une session est actuellement ouverte.",
            status_code=status.HTTP_409_CONFLICT,
        )

    reg_name = reg.name
    reg.is_active = False
    db.commit()
    return reg_name
