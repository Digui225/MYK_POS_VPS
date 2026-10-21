"""Dépendances FastAPI communes : utilisateur courant, RBAC, contexte de requête."""

from collections.abc import Callable
from typing import Annotated

from fastapi import Depends, Header, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.domain.enums import UserRole, role_at_least
from caisse.domain.ports import FneProvider
from caisse.errors import (
    InsufficientPrivilegeError,
    TerminalTokenInvalidError,
    TokenExpiredError,
)
from caisse.infrastructure.fne import get_fne_provider
from caisse.models.print_terminal import PrintTerminal
from caisse.models.user import User
from caisse.pagination import DEFAULT_LIMIT, MAX_LIMIT, PageRequest, decode_cursor
from caisse.services import auth_service, print_terminal_service
from caisse.services.audit_service import RequestContext

_bearer = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


def request_context(
    request: Request,
    x_device_id: Annotated[
        str | None,
        Header(max_length=64, description="Identifiant du poste (blocage des PIN, audit)"),
    ] = None,
) -> RequestContext:
    return RequestContext(device_id=x_device_id, ip=request.client.host if request.client else None)


Ctx = Annotated[RequestContext, Depends(request_context)]

OverrideTokenHeader = Annotated[
    str | None,
    Header(
        alias="X-Override-Token",
        description="Jeton obtenu par POST /auth/override (60 s, usage unique)",
    ),
]


def current_user(
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> User:
    if credentials is None:
        raise TokenExpiredError("Authentification requise")
    return auth_service.authenticate_access(db, credentials.credentials)


CurrentUser = Annotated[User, Depends(current_user)]


def require_role(minimum: UserRole) -> Callable[[User], User]:
    """Rôle minimal requis (CAISSIER < RESPONSABLE < ADMIN)."""

    def _check(user: CurrentUser) -> User:
        if not role_at_least(user.role, minimum):
            raise InsufficientPrivilegeError(meta={"required_role": minimum})
        return user

    return _check


Responsable = Annotated[User, Depends(require_role(UserRole.RESPONSABLE))]
Admin = Annotated[User, Depends(require_role(UserRole.ADMIN))]


def fne_provider() -> FneProvider | None:
    """Selon `FNE_PROVIDER` : API DGI, simulateur, ou `None` en mode manuel."""
    return get_fne_provider()


FneProviderDep = Annotated[FneProvider | None, Depends(fne_provider)]


def page_request(
    cursor: Annotated[
        str | None, Query(description="`next_cursor` de la page précédente ; absent : 1re page")
    ] = None,
    limit: Annotated[
        int, Query(ge=1, le=MAX_LIMIT, description="Nombre maximum d'éléments par page")
    ] = DEFAULT_LIMIT,
) -> PageRequest:
    return PageRequest(after=decode_cursor(cursor), limit=limit)


Paging = Annotated[PageRequest, Depends(page_request)]


def current_terminal(
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> PrintTerminal:
    """Agent d'impression : jeton du terminal (`pt_…`), jamais un JWT d'utilisateur."""
    if credentials is None:
        raise TerminalTokenInvalidError("Jeton de terminal requis")
    return print_terminal_service.authenticate(db, credentials.credentials)


CurrentTerminal = Annotated[PrintTerminal, Depends(current_terminal)]
