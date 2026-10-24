from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import get_current_user, require_role
from caisse.errors import CaisseException
from caisse.models.cash_session import CashRegister, CashSession
from caisse.models.settings import EstablishmentSetting
from caisse.models.user import User
from caisse.schemas.settings import (
    CashRegisterResponse,
    CreateCashRegisterRequest,
    EstablishmentSettingsResponse,
    UpdateCashRegisterRequest,
    UpdateEstablishmentSettingsRequest,
)

router = APIRouter(prefix="/settings", tags=["Paramètres Système"])


def _get_or_create_settings(db: Session) -> EstablishmentSetting:
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


@router.get("", response_model=EstablishmentSettingsResponse, summary="Consulter les paramètres de l'établissement")
async def get_establishment_settings(
    db: Session = Depends(get_db),
    _current_user: User = Depends(get_current_user),
) -> EstablishmentSettingsResponse:
    setting = _get_or_create_settings(db)
    return EstablishmentSettingsResponse.model_validate(setting)


@router.put("", response_model=EstablishmentSettingsResponse, summary="Mettre à jour les paramètres de l'établissement (Admin)")
async def update_establishment_settings(
    payload: UpdateEstablishmentSettingsRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> EstablishmentSettingsResponse:
    setting = _get_or_create_settings(db)

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

    db.commit()
    db.refresh(setting)
    return EstablishmentSettingsResponse.model_validate(setting)


# ==========================================
# Postes de Caisse (Cash Registers)
# ==========================================


@router.get("/registers", response_model=list[CashRegisterResponse], summary="Lister les postes de caisse")
async def list_cash_registers(
    db: Session = Depends(get_db),
    _current_user: User = Depends(get_current_user),
) -> list[CashRegisterResponse]:
    registers = db.query(CashRegister).order_by(CashRegister.created_at.asc()).all()
    if not registers:
        # Initialiser au moins la caisse principale si vide
        default_reg = CashRegister(
            id="0192384a-3000-7000-8000-000000000001",
            name="Caisse Principale",
            is_active=True,
        )
        db.add(default_reg)
        db.commit()
        db.refresh(default_reg)
        registers = [default_reg]

    # Vérifier les sessions actives pour chaque caisse
    open_sessions = (
        db.query(CashSession)
        .filter(CashSession.status == "OPEN")
        .all()
    )
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


@router.post("/registers", response_model=CashRegisterResponse, status_code=status.HTTP_201_CREATED, summary="Créer un poste de caisse (Admin)")
async def create_cash_register(
    payload: CreateCashRegisterRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> CashRegisterResponse:
    existing = db.query(CashRegister).filter(CashRegister.name == payload.name.strip()).first()
    if existing:
        raise CaisseException(
            code="REGISTER_ALREADY_EXISTS",
            title="Poste de caisse déjà existant",
            detail=f"Une caisse nommée '{payload.name.strip()}' existe déjà.",
            status_code=status.HTTP_409_CONFLICT,
        )

    reg = CashRegister(
        name=payload.name.strip(),
        is_active=True,
    )
    db.add(reg)
    db.commit()
    db.refresh(reg)

    return CashRegisterResponse(
        id=reg.id,
        name=reg.name,
        is_active=reg.is_active,
        has_active_session=False,
    )


@router.patch("/registers/{register_id}", response_model=CashRegisterResponse, summary="Modifier un poste de caisse (Admin)")
async def update_cash_register(
    register_id: str,
    payload: UpdateCashRegisterRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> CashRegisterResponse:
    reg = db.query(CashRegister).filter(CashRegister.id == register_id).first()
    if not reg:
        raise CaisseException(
            code="REGISTER_NOT_FOUND",
            title="Poste de caisse introuvable",
            detail=f"Aucune caisse avec l'identifiant '{register_id}' n'a été trouvée.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    if payload.name is not None and payload.name.strip() != reg.name:
        existing = db.query(CashRegister).filter(CashRegister.name == payload.name.strip()).first()
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
            # Vérifier qu'aucune session n'est ouverte
            open_session = (
                db.query(CashSession)
                .filter(CashSession.cash_register_id == reg.id, CashSession.status == "OPEN")
                .first()
            )
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

    active_session = (
        db.query(CashSession)
        .filter(CashSession.cash_register_id == reg.id, CashSession.status == "OPEN")
        .first()
    )

    return CashRegisterResponse(
        id=reg.id,
        name=reg.name,
        is_active=reg.is_active,
        has_active_session=bool(active_session),
        active_session_user=active_session.opened_by.full_name if active_session and active_session.opened_by else None,
        active_session_opened_at=active_session.opened_at.isoformat() if active_session and active_session.opened_at else None,
    )


@router.delete("/registers/{register_id}", summary="Désactiver un poste de caisse (Admin)")
async def delete_cash_register(
    register_id: str,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> dict[str, str]:
    reg = db.query(CashRegister).filter(CashRegister.id == register_id).first()
    if not reg:
        raise CaisseException(
            code="REGISTER_NOT_FOUND",
            title="Poste de caisse introuvable",
            detail=f"Aucune caisse avec l'identifiant '{register_id}' n'a été trouvée.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    open_session = (
        db.query(CashSession)
        .filter(CashSession.cash_register_id == reg.id, CashSession.status == "OPEN")
        .first()
    )
    if open_session:
        raise CaisseException(
            code="REGISTER_HAS_OPEN_SESSION",
            title="Session de caisse en cours",
            detail=f"Impossible de supprimer ou désactiver la caisse '{reg.name}' car une session est actuellement ouverte.",
            status_code=status.HTTP_409_CONFLICT,
        )

    reg.is_active = False
    db.commit()
    return {"message": f"Poste de caisse '{reg.name}' désactivé avec succès"}
