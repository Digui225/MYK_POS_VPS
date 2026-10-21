from fastapi import APIRouter, Depends, status

from caisse.deps import AuthenticatedUser, Ctx, CurrentUser, DbSession
from caisse.rate_limit import per_ip
from caisse.schemas.auth import (
    LoginRequest,
    MeResponse,
    OverrideRequest,
    OverrideResponse,
    RefreshRequest,
    TokenResponse,
)
from caisse.schemas.common import OpenSessionOut, UserOut
from caisse.services import auth_service
from caisse.services.audit_service import RequestContext
from caisse.services.auth_service import TokenPair

router = APIRouter(prefix="/auth", tags=["Authentification"])


def _token_response(db: DbSession, pair: TokenPair) -> TokenResponse:
    session = auth_service.current_open_session(db)
    return TokenResponse(
        access_token=pair.access_token,
        refresh_token=pair.refresh_token,
        expires_in=pair.expires_in,
        user=UserOut.model_validate(pair.user),
        open_session=OpenSessionOut.model_validate(session) if session else None,
    )


@router.post(
    "/login",
    response_model=TokenResponse,
    summary="Connexion par PIN",
    dependencies=[Depends(per_ip("login_rate_limit_per_minute"))],
)
def login(body: LoginRequest, db: DbSession, ctx: Ctx) -> TokenResponse:
    """Renvoie un jeton d'accès (15 min) et un jeton de renouvellement (12 h).

    Blocage progressif **par poste** (`device_id`) : au 5ᵉ PIN faux, le poste est bloqué 30 s,
    puis la durée double à chaque nouvel échec (15 min au plus). Une connexion réussie remet
    le compteur à zéro.

    Erreurs : `401 INVALID_CREDENTIALS` (`meta.remaining_attempts`),
    `423 ACCOUNT_LOCKED` (`meta.locked_until`), `422 VALIDATION_ERROR`.
    """
    # le device_id du corps fait foi pour la temporisation (X-Device-Id est facultatif)
    ctx = RequestContext(device_id=body.device_id, ip=ctx.ip)
    return _token_response(db, auth_service.login(db, body.pin, ctx))


@router.post(
    "/refresh",
    response_model=TokenResponse,
    summary="Renouveler les jetons",
    dependencies=[Depends(per_ip("refresh_rate_limit_per_minute"))],
)
def refresh(body: RefreshRequest, db: DbSession, ctx: Ctx) -> TokenResponse:
    """Échange un jeton de renouvellement contre une nouvelle paire de jetons.

    **Rotation** : le jeton envoyé est révoqué ; le réutiliser renvoie `401 TOKEN_EXPIRED`.
    """
    return _token_response(db, auth_service.refresh(db, body.refresh_token, ctx))


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, summary="Déconnexion")
def logout(body: RefreshRequest, user: AuthenticatedUser, db: DbSession, ctx: Ctx) -> None:
    """Révoque le jeton de renouvellement. Répond `204` même s'il est déjà invalide.

    Le jeton d'accès reste valable jusqu'à son expiration : le client doit l'oublier.
    """
    auth_service.logout(db, body.refresh_token, user, ctx)


@router.get("/me", response_model=MeResponse, summary="Utilisateur connecté")
def me(user: AuthenticatedUser, db: DbSession) -> MeResponse:
    """Utilisateur du jeton et session de caisse ouverte (null si aucune)."""
    session = auth_service.current_open_session(db)
    return MeResponse(
        user=UserOut.model_validate(user),
        open_session=OpenSessionOut.model_validate(session) if session else None,
    )


@router.post(
    "/override",
    response_model=OverrideResponse,
    summary="Autorisation ponctuelle d'un responsable",
    dependencies=[Depends(per_ip("login_rate_limit_per_minute"))],
)
def override(body: OverrideRequest, user: CurrentUser, db: DbSession, ctx: Ctx) -> OverrideResponse:
    """Un responsable saisit son PIN sur le poste du demandeur (connecté) et obtient un jeton
    valable 60 s, à usage unique, lié à l'action et au demandeur.

    Les PIN faux comptent dans le blocage du poste (`X-Device-Id`).

    Erreurs : `401 INVALID_CREDENTIALS`, `423 ACCOUNT_LOCKED`,
    `403 OVERRIDE_REQUIRED` (PIN valide mais rôle insuffisant).
    """
    grant = auth_service.authorize_override(
        db,
        body.pin,
        requested_by=user,
        action=body.action,
        required_role=body.required_role,
        ctx=ctx,
    )
    return OverrideResponse(
        override_token=grant.token,
        expires_in=grant.expires_in,
        granted_by=UserOut.model_validate(grant.granted_by),
    )
