from fastapi import APIRouter, Depends, Request, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import get_client_ip, get_current_user, require_device_id
from caisse.models.user import User
from caisse.schemas.auth import (
    LoginRequest,
    LoginResponse,
    OverrideRequest,
    OverrideResponse,
    RefreshTokenRequest,
    RefreshTokenResponse,
    UserResponse,
)
from caisse.core.config import get_settings
from caisse.core.errors import CaisseException
from caisse.security_rate_limit import login_lockout, require_rate_limit
from caisse.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["Authentification"])


@router.post(
    "/login",
    response_model=LoginResponse,
    summary="Connexion par code PIN",
    dependencies=[Depends(require_rate_limit(max_requests=10, window_seconds=60))],
)
async def login(
    payload: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> LoginResponse:
    ip = get_client_ip(request)
    key = ip or "unknown"
    retry_after = login_lockout.retry_after(key)
    if retry_after:
        raise CaisseException(
            code="PIN_LOCKOUT",
            title="Connexions bloquées",
            detail=f"Trop de codes PIN erronés depuis ce poste. Réessayez dans {retry_after} secondes.",
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            meta={"retry_after": retry_after},
        )
    auth_service = AuthService(db)
    try:
        response = auth_service.login_with_pin(
            pin=payload.pin,
            device_id=payload.device_id,
            ip=ip,
        )
    except CaisseException as exc:
        if exc.code == "INVALID_CREDENTIALS":
            settings = get_settings()
            login_lockout.record_failure(
                key, settings.PIN_MAX_FAILED_ATTEMPTS, settings.LOCKOUT_DURATION_MINUTES * 60
            )
        raise
    login_lockout.clear(key)
    return response


@router.post(
    "/refresh",
    response_model=RefreshTokenResponse,
    summary="Renouvellement du jeton JWT",
    dependencies=[Depends(require_rate_limit(max_requests=30, window_seconds=60))],
)
async def refresh_token(
    payload: RefreshTokenRequest,
    db: Session = Depends(get_db),
) -> RefreshTokenResponse:
    auth_service = AuthService(db)
    return auth_service.refresh(payload.refresh_token)


@router.post("/logout", status_code=status.HTTP_200_OK, summary="Déconnexion")
async def logout(current_user: User = Depends(get_current_user)) -> dict[str, str]:
    return {"message": "Déconnexion réussie"}


@router.get("/me", response_model=UserResponse, summary="Utilisateur connecté")
async def get_current_user_info(current_user: User = Depends(get_current_user)) -> UserResponse:
    return UserResponse(
        id=current_user.id,
        full_name=current_user.full_name,
        role=current_user.role,  # type: ignore
        is_active=current_user.is_active,
    )


@router.post(
    "/override",
    response_model=OverrideResponse,
    summary="Autorisation ponctuelle responsable",
    dependencies=[Depends(require_rate_limit(max_requests=10, window_seconds=60))],
)
async def create_override(
    payload: OverrideRequest,
    current_user: User = Depends(get_current_user),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> OverrideResponse:
    auth_service = AuthService(db)
    return auth_service.create_override(
        manager_pin=payload.manager_pin,
        reason=payload.reason,
        target_action=payload.target_action,
        current_user_id=current_user.id,
        device_id=device_id,
    )
