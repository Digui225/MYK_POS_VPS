from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from caisse.core.database import get_db
from caisse.core.deps import get_current_user, require_role
from caisse.models.user import User
from caisse.schemas.settings import (
    CashRegisterResponse,
    CreateCashRegisterRequest,
    EstablishmentSettingsResponse,
    UpdateCashRegisterRequest,
    UpdateEstablishmentSettingsRequest,
)
from caisse.services import settings_service

router = APIRouter(prefix="/settings", tags=["Paramètres Système"])


@router.get("", response_model=EstablishmentSettingsResponse, summary="Consulter les paramètres de l'établissement")
async def get_establishment_settings(
    db: Session = Depends(get_db),
    _current_user: User = Depends(get_current_user),
) -> EstablishmentSettingsResponse:
    return settings_service.get_establishment_settings(db)


@router.put("", response_model=EstablishmentSettingsResponse, summary="Mettre à jour les paramètres de l'établissement (Admin)")
async def update_establishment_settings(
    payload: UpdateEstablishmentSettingsRequest,
    db: Session = Depends(get_db),
    admin: User = Depends(require_role("ADMIN")),
) -> EstablishmentSettingsResponse:
    return settings_service.update_establishment_settings(db, payload, admin=admin)


@router.get("/registers", response_model=list[CashRegisterResponse], summary="Lister les postes de caisse")
async def list_cash_registers(
    db: Session = Depends(get_db),
    _current_user: User = Depends(get_current_user),
) -> list[CashRegisterResponse]:
    return settings_service.list_cash_registers(db)


@router.post("/registers", response_model=CashRegisterResponse, status_code=status.HTTP_201_CREATED, summary="Créer un poste de caisse (Admin)")
async def create_cash_register(
    payload: CreateCashRegisterRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> CashRegisterResponse:
    return settings_service.create_cash_register(db, payload)


@router.patch("/registers/{register_id}", response_model=CashRegisterResponse, summary="Modifier un poste de caisse (Admin)")
async def update_cash_register(
    register_id: str,
    payload: UpdateCashRegisterRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> CashRegisterResponse:
    return settings_service.update_cash_register(db, register_id, payload)


@router.delete("/registers/{register_id}", summary="Désactiver un poste de caisse (Admin)")
async def delete_cash_register(
    register_id: str,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_role("ADMIN")),
) -> dict[str, str]:
    reg_name = settings_service.delete_cash_register(db, register_id)
    return {"message": f"Poste de caisse '{reg_name}' désactivé avec succès"}
