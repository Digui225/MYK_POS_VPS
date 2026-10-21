import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from pathlib import Path

import structlog
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from caisse import __version__
from caisse.api import health
from caisse.api.v1.router import api_router
from caisse.config import get_settings
from caisse.database import get_engine
from caisse.errors import PROBLEM_JSON, install_error_handlers
from caisse.logging import configure_logging

log = structlog.get_logger()

# Swagger UI 5.17.14 (swagger-ui-dist, Apache-2.0) servi par l'API : le CDN par défaut de FastAPI
# (cdn.jsdelivr.net, Cloudflare) est injoignable depuis certains réseaux d'Abidjan → page blanche
SWAGGER_UI_DIR = Path(__file__).parent / "static" / "swagger-ui"

API_DESCRIPTION = """Contrat v1 : voir `03-CONTRAT-API.md`.

- Les noms de champs sont en anglais (`snake_case`) ; leur sens est décrit en français.
- Montants en **entiers XOF**. Dates en ISO 8601 UTC.
- Erreurs au format `application/problem+json` : se fier au champ `code`.
- Pour tester : `POST /api/v1/auth/login`, copier `access_token`, puis bouton **Authorize**.
"""

OPENAPI_TAGS = [
    {
        "name": "Authentification",
        "description": "Connexion par PIN, jetons, autorisation ponctuelle d'un responsable",
    },
    {"name": "Utilisateurs", "description": "Gestion des comptes (ADMIN)"},
    {"name": "Catalogue", "description": "Catégories et produits du menu (lecture)"},
    {"name": "Tables", "description": "Salle et écran d'accueil"},
    {"name": "Santé", "description": "Supervision : service vivant, base, imprimante, files"},
]


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    log.info("startup", env=settings.app_env, fne_provider=settings.fne_provider)
    yield
    get_engine().dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    configure_logging(json_logs=settings.is_production)

    docs = settings.docs_enabled  # coupés en production, sauf ENABLE_DOCS=true
    app = FastAPI(
        title="Caisse restaurant — API",
        version=__version__,
        description=API_DESCRIPTION,
        openapi_tags=OPENAPI_TAGS,
        lifespan=lifespan,
        docs_url=None,  # servi ci-dessous, sans CDN
        redoc_url=None,  # ReDoc dépendrait lui aussi d'un CDN : Swagger suffit
        openapi_url="/openapi.json" if docs else None,
    )
    if docs:
        app.mount("/docs/static", StaticFiles(directory=SWAGGER_UI_DIR), name="swagger-ui")

        @app.get("/docs", include_in_schema=False)
        def swagger_ui() -> HTMLResponse:
            return get_swagger_ui_html(
                openapi_url="/openapi.json",
                title=f"{app.title} - Swagger UI",
                swagger_js_url="/docs/static/swagger-ui-bundle.js",
                swagger_css_url="/docs/static/swagger-ui.css",
                swagger_favicon_url="data:,",
            )

    @app.middleware("http")
    async def security_headers(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
        return response

    @app.middleware("http")
    async def body_size_limit(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        """Refuse sur `Content-Length` avant de lire le corps (413 problem+json)."""
        try:
            length = int(request.headers.get("content-length") or 0)
        except ValueError:
            length = 0
        limit = settings.max_request_body_bytes
        if length > limit:
            return JSONResponse(
                {
                    "type": "https://caisse.local/errors/payload-too-large",
                    "title": "Corps de requête trop volumineux",
                    "status": 413,
                    "code": "PAYLOAD_TOO_LARGE",
                    "detail": f"{length} octets reçus, {limit} au plus.",
                    "meta": {"max_bytes": limit, "received_bytes": length},
                    "request_id": getattr(request.state, "request_id", None),
                },
                status_code=413,
                media_type=PROBLEM_JSON,
            )
        return await call_next(request)

    @app.middleware("http")
    async def request_id(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        rid = request.headers.get("X-Request-Id") or str(uuid.uuid4())
        request.state.request_id = rid
        structlog.contextvars.clear_contextvars()
        structlog.contextvars.bind_contextvars(request_id=rid, path=request.url.path)
        response = await call_next(request)
        response.headers["X-Request-Id"] = rid
        return response

    # `CORS_ORIGINS=*` (dev uniquement) : aucun cookie n'est utilisé, l'authentification passe
    # par `Authorization: Bearer`, donc `allow_credentials` peut rester à False. C'est nécessaire :
    # un navigateur rejette la combinaison origin "*" + credentials true. Ignoré en production,
    # où une liste explicite d'origines est requise.
    wildcard = settings.cors_origins == ["*"]
    if wildcard and settings.is_production:
        log.warning("cors_wildcard_ignored_in_production")
    origins = [] if (wildcard and settings.is_production) else settings.cors_origins
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=not wildcard,
            allow_methods=["*"],
            allow_headers=["*"],
            expose_headers=["X-Request-Id", "Idempotent-Replay"],
        )

    if settings.allowed_hosts and "*" not in settings.allowed_hosts:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)

    install_error_handlers(app)
    app.include_router(health.router)
    app.include_router(health.router, prefix="/api/v1")  # même route, derrière le proxy nginx
    app.include_router(api_router)
    return app


app = create_app()
