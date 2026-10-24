import logging
from datetime import datetime, timezone

from fastapi import status
from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.errors import CaisseException
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
from caisse.security import (
    create_access_token,
    create_override_token,
    create_refresh_token,
    decode_token,
    hash_pin,
    verify_pin,
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

    def login_with_pin(self, pin: str, device_id: str, ip: str | None = None) -> LoginResponse:
        # Chercher parmi tous les utilisateurs actifs
        users = self.user_repo.list_all()
        matched_user: User | None = None

        for u in users:
            if not u.is_active:
                continue
            if u.is_locked():
                continue
            if verify_pin(pin, u.pin_hash):
                matched_user = u
                break

        if not matched_user:
            logger.warning(
                "Tentative de connexion par code PIN échouée depuis l'IP %s (poste: %s)",
                ip or "inconnue",
                device_id,
            )
            # Traçabilité tentative infructueuse
            self.audit.log(
                action="LOGIN_FAILED",
                entity="AUTH",
                reason="PIN erroné ou utilisateur verrouillé",
                device_id=device_id,
                ip=ip,
            )
            self.db.commit()
            raise CaisseException(
                code="INVALID_CREDENTIALS",
                title="Code PIN invalide",
                detail="Le code PIN saisi est incorrect ou le compte est bloqué.",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        # Réinitialisation des tentatives et mise à jour last_login
        matched_user.failed_attempts = 0
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
