from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import require_role
from caisse.errors import CaisseException
from caisse.models.user import User
from caisse.repositories.users import UserRepository
from caisse.schemas.auth import (
    CreateUserRequest,
    ResetPinRequest,
    UpdateUserRequest,
    UserResponse,
)
from caisse.schemas.common import PaginatedResponse
from caisse.security import hash_pin
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
    user_repo = UserRepository(db)
    user = user_repo.get_by_id(user_id)
    if not user:
        raise CaisseException(
            code="USER_NOT_FOUND",
            title="Utilisateur introuvable",
            detail=f"Aucun utilisateur avec l'identifiant '{user_id}' n'a été trouvé.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    if payload.full_name is not None and payload.full_name != user.full_name:
        existing = user_repo.get_by_name(payload.full_name)
        if existing and existing.id != user.id:
            raise CaisseException(
                code="USER_ALREADY_EXISTS",
                title="Nom déjà utilisé",
                detail=f"Un utilisateur avec le nom '{payload.full_name}' existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )
        user.full_name = payload.full_name

    if payload.role is not None:
        user.role = payload.role

    if payload.is_active is not None:
        user.is_active = payload.is_active

    db.commit()
    db.refresh(user)
    return UserResponse.model_validate(user)


@router.post("/{user_id}/pin", summary="Réinitialiser le code PIN (Admin)")
async def reset_user_pin(
    user_id: str,
    payload: ResetPinRequest,
    db: Session = Depends(get_db),
    _current_user: User = Depends(require_role("ADMIN")),
) -> dict[str, str]:
    user_repo = UserRepository(db)
    user = user_repo.get_by_id(user_id)
    if not user:
        raise CaisseException(
            code="USER_NOT_FOUND",
            title="Utilisateur introuvable",
            detail=f"Aucun utilisateur avec l'identifiant '{user_id}' n'a été trouvé.",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    user.pin_hash = hash_pin(payload.new_pin)
    user.failed_attempts = 0
    user.locked_until = None
    db.commit()
    return {"message": f"Code PIN de '{user.full_name}' mis à jour avec succès"}
