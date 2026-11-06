from fastapi import APIRouter, Depends, Request, status
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.core.database import get_db
from caisse.core.deps import get_client_ip, get_current_user, require_device_id
from caisse.core.errors import CaisseException
from caisse.core.security_rate_limit import enforce_rate_limit, login_lockout, require_rate_limit
from caisse.models.user import User
from caisse.schemas.auth import (
    LoginRequest,
    LoginResponse,
    OverrideRequest,
    OverrideResponse,
    RefreshTokenRequest,
    RefreshTokenResponse,
    StaffMemberResponse,
    UserResponse,
)
from caisse.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["Authentification"])


@router.get(
    "/staff",
    response_model=list[StaffMemberResponse],
    summary="Serveurs actifs (écran de prise de service, avant connexion)",
    dependencies=[Depends(require_rate_limit(max_requests=30, window_seconds=60))],
)
async def list_staff(db: Session = Depends(get_db)) -> list[StaffMemberResponse]:
    """Noms des comptes SERVEUR actifs, pour choisir son nom avant de taper son PIN."""
    return [
        StaffMemberResponse(id=u.id, full_name=u.full_name) for u in AuthService(db).list_staff()
    ]


@router.post(
    "/login",
    response_model=LoginResponse,
    summary="Connexion par code PIN",
)
async def login(
    payload: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> LoginResponse:
    settings = get_settings()
    auth_service = AuthService(db)

    if payload.user_id is not None:
        # Compte choisi puis PIN (appareils de salle) : quota et blocage portent sur le compte,
        # car tous les téléphones de la salle sortent par la même adresse que la caisse.
        enforce_rate_limit(
            f"user:{request.url.path}:{payload.user_id}",
            max_requests=10,
            window_seconds=60,
            source=f"{request.url.path} pour le compte {payload.user_id}",
        )
        return auth_service.login_with_pin(
            pin=payload.pin,
            device_id=payload.device_id,
            ip=get_client_ip(request),
            user_id=payload.user_id,
        )

    # PIN seul (caisse) : un PIN faux ne désigne aucun compte, le blocage porte sur le poste.
    client_host = request.client.host if request.client else "unknown"
    enforce_rate_limit(
        f"ip:{request.url.path}:{client_host}",
        max_requests=10,
        window_seconds=60,
        source=f"{request.url.path} depuis l'adresse IP {client_host}",
    )
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
    try:
        response = auth_service.login_with_pin(
            pin=payload.pin,
            device_id=payload.device_id,
            ip=ip,
        )
    except CaisseException as exc:
        if exc.code == "INVALID_CREDENTIALS":
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
