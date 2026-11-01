from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from caisse.core.database import get_db
from caisse.core.deps import require_role
from caisse.models.user import User
from caisse.repositories.users import UserRepository
from caisse.schemas.auth import (
    CreateUserRequest,
    ResetPinRequest,
    UpdateUserRequest,
    UserResponse,
)
from caisse.schemas.common import PaginatedResponse
from caisse.services.auth_service import AuthService

router = APIRouter(prefix="/users", tags=["Utilisateurs"])


@router.get("", response_model=PaginatedResponse[UserResponse], summary="Lister les utilisateurs (Admin/Responsable)")
async def list_users(
    db: Session = Depends(get_db),
    _current_user: User = Depends(require_role("ADMIN", "RESPONSABLE")),
) -> PaginatedResponse[UserResponse]:
    users = UserRepository(db).list_all(limit=100)
    return PaginatedResponse(
        items=[UserResponse.model_validate(u) for u in users],
        next_cursor=None,
    )


@router.post("", response_model=UserResponse, status_code=status.HTTP_201_CREATED, summary="Créer un utilisateur (Admin)")
async def create_user(
    payload: CreateUserRequest,
    db: Session = Depends(get_db),
    _current_user: User = Depends(require_role("ADMIN")),
) -> UserResponse:
    auth_service = AuthService(db)
    user = auth_service.create_user(
        full_name=payload.full_name,
        pin=payload.pin,
        role=payload.role,
    )
    return UserResponse.model_validate(user)


@router.patch("/{user_id}", response_model=UserResponse, summary="Modifier un utilisateur (Admin)")
async def update_user(
    user_id: str,
    payload: UpdateUserRequest,
    db: Session = Depends(get_db),
    _current_user: User = Depends(require_role("ADMIN")),
) -> UserResponse:
    auth_service = AuthService(db)
    user = auth_service.update_user(
        user_id,
        full_name=payload.full_name,
        role=payload.role,
        is_active=payload.is_active,
    )
    return UserResponse.model_validate(user)


@router.post("/{user_id}/pin", summary="Réinitialiser le code PIN (Admin)")
async def reset_user_pin(
    user_id: str,
    payload: ResetPinRequest,
    db: Session = Depends(get_db),
    _current_user: User = Depends(require_role("ADMIN")),
) -> dict[str, str]:
    auth_service = AuthService(db)
    user = auth_service.reset_user_pin(user_id, payload.new_pin)
    return {"message": f"Code PIN de '{user.full_name}' mis à jour avec succès"}
