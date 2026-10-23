import uuid
from collections.abc import Callable
from typing import Any
from fastapi import Depends, Header, Query, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.errors import CaisseException
from caisse.models.user import User
from caisse.pagination import DEFAULT_LIMIT, MAX_LIMIT, PageRequest, decode_cursor
from caisse.repositories.users import UserRepository
from caisse.security import decode_token

security = HTTPBearer(auto_error=False)


def get_request_id(request: Request, x_request_id: str | None = Header(None)) -> str:
    req_id = x_request_id or str(uuid.uuid4())
    request.state.request_id = req_id
    return req_id


def get_client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


def require_device_id(x_device_id: str | None = Header(None, alias="X-Device-Id")) -> str:
    return x_device_id or "default-pos-device"


def require_idempotency_key(idempotency_key: str | None = Header(None, alias="Idempotency-Key")) -> str:
    if not idempotency_key:
        raise CaisseException(
            code="IDEMPOTENCY_KEY_REQUIRED",
            title="Clé d'idempotence manquante",
            detail="L'en-tête Idempotency-Key est obligatoire pour cette opération financière.",
            status_code=status.HTTP_400_BAD_REQUEST,
        )
    return idempotency_key


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    db: Session = Depends(get_db),
) -> User:
    if not credentials:
        raise CaisseException(
            code="AUTHENTICATION_REQUIRED",
            title="Authentification requise",
            detail="Veuillez fournir un jeton Bearer valide.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    token = credentials.credentials
    payload = decode_token(token)
    user_id = payload.get("sub")
    if not user_id:
        raise CaisseException(
            code="INVALID_TOKEN",
            title="Jeton invalide",
            detail="Identifiant utilisateur introuvable dans le jeton.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    user = UserRepository(db).get_by_id(user_id)
    if not user or not user.is_active:
        raise CaisseException(
            code="USER_NOT_FOUND_OR_INACTIVE",
            title="Utilisateur introuvable ou inactif",
            detail="Ce compte utilisateur est désactivé ou n'existe plus.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    if user.is_locked():
        raise CaisseException(
            code="ACCOUNT_LOCKED",
            title="Compte temporairement bloqué",
            detail=f"Trop de tentatives infructueuses. Réessayez après {user.locked_until}.",
            status_code=status.HTTP_423_LOCKED,
            meta={"locked_until": user.locked_until.isoformat() if user.locked_until else None},
        )

    return user


def require_role(*allowed_roles: str) -> Callable[[User], User]:
    def role_dependency(current_user: User = Depends(get_current_user)) -> User:
        if current_user.role not in allowed_roles:
            raise CaisseException(
                code="INSUFFICIENT_PRIVILEGE",
                title="Droits insuffisants",
                detail=f"Cette action requiert l'un des rôles suivants : {', '.join(allowed_roles)}.",
                status_code=status.HTTP_403_FORBIDDEN,
            )
        return current_user

    return role_dependency


def get_fne_provider() -> Any:
    from caisse.config import get_settings
    from caisse.infrastructure.fne.http_client import HttpFneProvider
    from caisse.infrastructure.fne.mock import MockFneProvider

    settings = get_settings()
    if settings.fne_provider == "api":
        return HttpFneProvider(settings.fne_api_base_url, settings.fne_api_key)
    return MockFneProvider()


from typing import Annotated

class RequestContext:
    def __init__(self, device_id: str, client_ip: str | None = None, request_id: str | None = None):
        self.device_id = device_id
        self.ip = client_ip
        self.request_id = request_id


def get_request_context(
    device_id: str = Depends(require_device_id),
    client_ip: str | None = Depends(get_client_ip),
    request_id: str = Depends(get_request_id),
) -> RequestContext:
    return RequestContext(device_id=device_id, client_ip=client_ip, request_id=request_id)


def page_request(
    cursor: Annotated[
        str | None, Query(description="`next_cursor` de la page précédente ; absent : 1re page")
    ] = None,
    limit: Annotated[
        int, Query(ge=1, le=MAX_LIMIT, description="Nombre maximum d'éléments par page")
    ] = DEFAULT_LIMIT,
) -> PageRequest:
    return PageRequest(after=decode_cursor(cursor), limit=limit)


DbSession = Annotated[Session, Depends(get_db)]
AuthenticatedUser = Annotated[User, Depends(get_current_user)]
CurrentUser = Annotated[User, Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME"))]
Responsable = Annotated[User, Depends(require_role("RESPONSABLE", "ADMIN"))]
Admin = Annotated[User, Depends(require_role("ADMIN"))]
MarketPurchaser = Annotated[User, Depends(require_role("ECONOME", "CAISSIER", "RESPONSABLE", "ADMIN"))]
EconomeOnly = Annotated[User, Depends(require_role("ECONOME", "RESPONSABLE", "ADMIN"))]
Acheteur = Annotated[User, Depends(require_role("ECONOME", "RESPONSABLE", "ADMIN"))]
Ctx = Annotated[RequestContext, Depends(get_request_context)]
Paging = Annotated[PageRequest, Depends(page_request)]
FneProviderDep = Annotated[Any, Depends(get_fne_provider)]


def get_current_terminal(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    db: Session = Depends(get_db),
):
    from caisse.models.print_terminal import PrintTerminal
    from caisse.services.print_terminal_service import PrintTerminalService

    if not credentials:
        raise CaisseException(
            code="TERMINAL_TOKEN_INVALID",
            title="Jeton requis",
            detail="Veuillez fournir un jeton Bearer valide.",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )
    token = credentials.credentials
    service = PrintTerminalService(db)
    return service.authenticate(token)


CurrentTerminal = Annotated[Any, Depends(get_current_terminal)]

