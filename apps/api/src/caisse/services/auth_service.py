import logging
from datetime import datetime, timedelta, timezone

from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.core.errors import CaisseException
from caisse.core.security import (
    create_access_token,
    create_override_token,
    create_refresh_token,
    decode_token,
    hash_pin,
    verify_pin,
)
from caisse.domain.enums import UserRole
from caisse.models.user import User
from caisse.repositories.sessions import CashSessionRepository
from caisse.repositories.users import UserRepository
from caisse.schemas.auth import (
    LoginResponse,
    OpenSessionInfo,
    OverrideResponse,
    RefreshTokenResponse,
    UserResponse,
)
from caisse.services.audit_service import AuditService

logger = logging.getLogger("caisse.security")
settings = get_settings()


class AuthService:
    def __init__(self, db: Session):
        self.db = db
        self.user_repo = UserRepository(db)
        self.session_repo = CashSessionRepository(db)
        self.audit = AuditService(db)

    def list_staff(self) -> list[User]:
        """Serveurs actifs proposés sur l'écran de prise de service des appareils de salle."""
        return self.user_repo.list_active_by_role(UserRole.SERVEUR)

    def login_with_pin(
        self, pin: str, device_id: str, ip: str | None = None, user_id: str | None = None
    ) -> LoginResponse:
        """Connexion par PIN seul (caisse) ou par compte choisi puis PIN (appareils de salle)."""
        if user_id is not None:
            matched_user = self._match_account_pin(user_id, pin, device_id, ip)
        else:
            matched_user = self._match_any_pin(pin, device_id, ip)
        return self._open_session(matched_user, device_id, ip)

    def _invalid_credentials(self, device_id: str, ip: str | None, user_id: str | None = None) -> CaisseException:
        logger.warning(
            "Tentative de connexion par code PIN échouée depuis l'IP %s (poste: %s)",
            ip or "inconnue",
            device_id,
        )
        # Traçabilité tentative infructueuse
        self.audit.log(
            action="LOGIN_FAILED",
            entity="AUTH",
            entity_id=user_id,
            reason="PIN erroné ou utilisateur verrouillé",
            device_id=device_id,
            ip=ip,
        )
        self.db.commit()
        return CaisseException(
            code="INVALID_CREDENTIALS",
            title="Code PIN invalide",
            detail="Le code PIN saisi est incorrect ou le compte est bloqué.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    def _match_any_pin(self, pin: str, device_id: str, ip: str | None) -> User:
        # Chercher parmi tous les utilisateurs actifs
        for u in self.user_repo.list_all():
            if not u.is_active:
                continue
            if u.is_locked():
                continue
            if verify_pin(pin, u.pin_hash):
                return u
        raise self._invalid_credentials(device_id, ip)

    def _match_account_pin(self, user_id: str, pin: str, device_id: str, ip: str | None) -> User:
        """PIN d'un compte désigné : le blocage après PIN erronés porte sur ce compte, pas sur
        le poste (tous les téléphones de la salle sortent par la même adresse)."""
        user = self.user_repo.get_by_id(user_id)
        if user is None or not user.is_active:
            raise self._invalid_credentials(device_id, ip, user_id)
        if user.is_locked() and user.locked_until is not None:
            locked_until = user.locked_until
            if locked_until.tzinfo is None:
                locked_until = locked_until.replace(tzinfo=timezone.utc)
            retry_after = max(1, int((locked_until - datetime.now(timezone.utc)).total_seconds()))
            raise CaisseException(
                code="PIN_LOCKOUT",
                title="Compte bloqué",
                detail=f"Trop de codes PIN erronés pour ce compte. Réessayez dans {retry_after} secondes.",
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                meta={"retry_after": retry_after},
            )
        if not verify_pin(pin, user.pin_hash):
            user.failed_attempts += 1
            if user.failed_attempts >= settings.PIN_MAX_FAILED_ATTEMPTS:
                user.locked_until = datetime.now(timezone.utc) + timedelta(
                    minutes=settings.LOCKOUT_DURATION_MINUTES
                )
                user.failed_attempts = 0
                logger.warning(
                    "Compte %s bloqué %s min : %d PIN erronés",
                    user.id,
                    settings.LOCKOUT_DURATION_MINUTES,
                    settings.PIN_MAX_FAILED_ATTEMPTS,
                )
            raise self._invalid_credentials(device_id, ip, user.id)
        return user

    def _open_session(self, matched_user: User, device_id: str, ip: str | None) -> LoginResponse:
        # Réinitialisation des tentatives et mise à jour last_login
        matched_user.failed_attempts = 0
        matched_user.locked_until = None
        matched_user.last_login_at = datetime.now(timezone.utc)

        # Vérifier si une session est ouverte sur la caisse
        register = self.session_repo.get_or_create_default_register()
        active_session = self.session_repo.get_active_by_register_id(register.id)

        open_session_info = None
        if active_session:
            open_session_info = OpenSessionInfo(
                id=active_session.id,
                business_date=active_session.business_date.isoformat(),
                cash_register_id=active_session.cash_register_id,
            )

        access_token = create_access_token(matched_user.id, matched_user.role, device_id)
        refresh_token = create_refresh_token(matched_user.id, device_id)

        self.audit.log(
            action="LOGIN_SUCCESS",
            entity="USER",
            entity_id=matched_user.id,
            user_id=matched_user.id,
            device_id=device_id,
            ip=ip,
        )
        self.db.commit()

        return LoginResponse(
            access_token=access_token,
            refresh_token=refresh_token,
            token_type="bearer",
            expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
            user=UserResponse(
                id=matched_user.id,
                full_name=matched_user.full_name,
                role=matched_user.role,  # type: ignore
                is_active=matched_user.is_active,
            ),
            open_session=open_session_info,
        )

    def refresh(self, refresh_token: str) -> RefreshTokenResponse:
        payload = decode_token(refresh_token)
        if payload.get("type") != "refresh":
            raise CaisseException(
                code="INVALID_TOKEN_TYPE",
                title="Type de jeton invalide",
                detail="Le jeton fourni n'est pas un jeton de rafraîchissement.",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        user_id = payload.get("sub")
        if not user_id or not isinstance(user_id, str):
            raise CaisseException(
                code="INVALID_TOKEN",
                title="Jeton invalide",
                detail="Le jeton fourni ne contient pas d'identifiant utilisateur valide.",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )
        user = self.user_repo.get_by_id(user_id)
        if not user or not user.is_active or user.is_locked():
            raise CaisseException(
                code="USER_INACTIVE_OR_LOCKED",
                title="Compte inactif ou verrouillé",
                detail="L'utilisateur n'est plus autorisé à se connecter.",
                status_code=status.HTTP_403_FORBIDDEN,
            )

        new_access_token = create_access_token(user.id, user.role, payload.get("device_id"))
        return RefreshTokenResponse(
            access_token=new_access_token,
            token_type="bearer",
            expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        )

    def create_override(self, manager_pin: str, reason: str, target_action: str, current_user_id: str, device_id: str | None = None) -> OverrideResponse:
        users = self.user_repo.list_all()
        authorizing_manager: User | None = None

        for u in users:
            if u.role in ["RESPONSABLE", "ADMIN"] and u.is_active and not u.is_locked():
                if verify_pin(manager_pin, u.pin_hash):
                    authorizing_manager = u
                    break

        if not authorizing_manager:
            raise CaisseException(
                code="OVERRIDE_FAILED",
                title="Autorisation refusée",
                detail="Le code PIN responsable saisi est invalide ou le compte n'a pas les privilèges requis.",
                status_code=status.HTTP_403_FORBIDDEN,
            )

        override_token = create_override_token(
            manager_id=authorizing_manager.id,
            manager_name=authorizing_manager.full_name,
            target_action=target_action,
        )

        self.audit.log(
            action="OVERRIDE_GRANTED",
            entity="AUTH",
            user_id=current_user_id,
            acting_as_user_id=authorizing_manager.id,
            reason=f"Action '{target_action}' autorisée : {reason}",
            device_id=device_id,
        )
        self.db.commit()

        return OverrideResponse(
            override_token=override_token,
            expires_in=60,
            authorized_by=f"{authorizing_manager.full_name} ({authorizing_manager.role})",
        )

    def create_user(self, full_name: str, pin: str, role: str) -> User:
        existing = self.user_repo.get_by_name(full_name)
        if existing:
            raise CaisseException(
                code="USER_ALREADY_EXISTS",
                title="Utilisateur déjà existant",
                detail=f"Un utilisateur avec le nom '{full_name}' existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )

        hashed = hash_pin(pin)
        user = User(
            full_name=full_name,
            pin_hash=hashed,
            role=role,
            is_active=True,
        )
        created = self.user_repo.add(user)
        self.db.commit()
        return created

    def update_user(
        self,
        user_id: str,
        *,
        full_name: str | None = None,
        role: str | None = None,
        is_active: bool | None = None,
    ) -> User:
        user = self.user_repo.get_by_id(user_id)
        if not user:
            raise CaisseException(
                code="USER_NOT_FOUND",
                title="Utilisateur introuvable",
                detail=f"Aucun utilisateur avec l'identifiant '{user_id}' n'a été trouvé.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if full_name is not None and full_name != user.full_name:
            existing = self.user_repo.get_by_name(full_name)
            if existing and existing.id != user.id:
                raise CaisseException(
                    code="USER_ALREADY_EXISTS",
                    title="Nom déjà utilisé",
                    detail=f"Un utilisateur avec le nom '{full_name}' existe déjà.",
                    status_code=status.HTTP_409_CONFLICT,
                )
            user.full_name = full_name

        if role is not None:
            user.role = role

        if is_active is not None:
            user.is_active = is_active

        self.db.commit()
        self.db.refresh(user)
        return user

    def reset_user_pin(self, user_id: str, new_pin: str) -> User:
        user = self.user_repo.get_by_id(user_id)
        if not user:
            raise CaisseException(
                code="USER_NOT_FOUND",
                title="Utilisateur introuvable",
                detail=f"Aucun utilisateur avec l'identifiant '{user_id}' n'a été trouvé.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        user.pin_hash = hash_pin(new_pin)
        user.failed_attempts = 0
        user.locked_until = None
        self.db.commit()
        return user
