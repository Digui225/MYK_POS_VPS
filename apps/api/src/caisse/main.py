import uuid
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from caisse.api.v1.router import api_v1_router
from caisse.config import get_settings
from caisse.database import Base, engine, get_db
from caisse.errors import (
    CaisseException,
    caisse_exception_handler,
    problem_json_response,
    unhandled_exception_handler,
    validation_exception_handler,
)
from caisse.schemas.common import HealthReadyResponse, HealthResponse

settings = get_settings()


import asyncio

from caisse.infrastructure.outbox.worker import run_outbox_worker_loop


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    # Startup : s'assurer que toutes les tables sont créées
    if settings.APP_ENV != "test":
        Base.metadata.create_all(bind=engine)

    worker_task = None
    stop_event = asyncio.Event()

    # Démarrage du worker Outbox d'arrière-plan si activé
    if getattr(settings, "ENABLE_OUTBOX_WORKER", True) and settings.APP_ENV != "test":
        worker_task = asyncio.create_task(
            run_outbox_worker_loop(
                stop_event,
                interval_seconds=getattr(settings, "OUTBOX_WORKER_INTERVAL_SECONDS", 30.0),
            )
        )

    yield

    # Shutdown
    if worker_task:
        stop_event.set()
        try:
            await asyncio.wait_for(worker_task, timeout=5.0)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            pass


from pathlib import Path

from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

SWAGGER_UI_DIR = Path(__file__).parent / "static" / "swagger-ui"

app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    description="API Backend de Caisse Restaurant (OsisPos) - Point de Vente & Facturation Normalisée",
    openapi_url="/openapi.json" if settings.docs_enabled else None,
    docs_url=None,
    redoc_url=None,
    lifespan=lifespan,
)

if settings.docs_enabled and SWAGGER_UI_DIR.exists():
    app.mount("/docs/static", StaticFiles(directory=str(SWAGGER_UI_DIR)), name="swagger-ui")


@app.get("/docs", include_in_schema=False)
@app.get("/", include_in_schema=False)
async def custom_swagger_ui_html() -> HTMLResponse:
    if not settings.docs_enabled:
        raise CaisseException(
            code="DOCS_DISABLED",
            title="Documentation désactivée",
            detail="La documentation interactive est désactivée en environnement de production.",
            status_code=404,
        )
    return get_swagger_ui_html(
        openapi_url="/openapi.json",
        title=f"{settings.APP_NAME} - Swagger UI",
        swagger_js_url="/docs/static/swagger-ui-bundle.js",
        swagger_css_url="/docs/static/swagger-ui.css",
        swagger_favicon_url="data:,",
    )


# Middlewares
@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):  # type: ignore
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    return response


@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):  # type: ignore
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            length = int(content_length)
            if length > settings.MAX_REQUEST_BODY_SIZE:
                request_id = getattr(request.state, "request_id", str(uuid.uuid4()))
                return problem_json_response(
                    status_code=413,
                    code="PAYLOAD_TOO_LARGE",
                    title="Corps de requête trop volumineux",
                    detail=f"La taille de la requête ({length} octets) dépasse la limite autorisée de {settings.MAX_REQUEST_BODY_SIZE} octets.",
                    request_id=request_id,
                    meta={"max_bytes": settings.MAX_REQUEST_BODY_SIZE, "received_bytes": length},
                )
        except ValueError:
            pass
    return await call_next(request)


@app.middleware("http")
async def request_id_middleware(request: Request, call_next):  # type: ignore
    request_id = request.headers.get("X-Request-Id", str(uuid.uuid4()))
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-Id"] = request_id
    return response


# TrustedHostMiddleware (vérifie que l'en-tête Host correspond aux domaines autorisés)
if settings.ALLOWED_HOSTS and "*" not in settings.ALLOWED_HOSTS:
    app.add_middleware(
        TrustedHostMiddleware,
        allowed_hosts=settings.ALLOWED_HOSTS,
    )

# CORSMiddleware ajouté en dernier pour être le wrapper le plus externe (capture toutes les réponses y compris erreurs 500)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)


# Enregistrement des gestionnaires d'erreurs RFC 7807 (problem+json)
app.add_exception_handler(CaisseException, caisse_exception_handler)  # type: ignore
app.add_exception_handler(RequestValidationError, validation_exception_handler)  # type: ignore
app.add_exception_handler(Exception, unhandled_exception_handler)

# Routes système / Health
@app.get("/health", response_model=HealthResponse, tags=["Système"])
async def health_check() -> HealthResponse:
    return HealthResponse(
        status="ok",
        app=settings.APP_NAME,
        environment=settings.APP_ENV,
    )


@app.get("/health/ready", response_model=HealthReadyResponse, tags=["Système"])
async def health_ready(db: Session = Depends(get_db)) -> HealthReadyResponse:
    import httpx
    from sqlalchemy import text

    from caisse.domain.enums import FneStatus
    from caisse.models.fne import FneDocument

    db_ok = False
    fne_queue = 0
    try:
        db.execute(text("SELECT 1"))
        db_ok = True
        fne_queue = (
            db.query(FneDocument)
            .filter(FneDocument.status.in_([FneStatus.QUEUED, FneStatus.PENDING]))
            .count()
        )
    except Exception:
        db_ok = False

    print_agent_ok = False
    try:
        async with httpx.AsyncClient(timeout=0.6) as client:
            resp = await client.get(f"{settings.PRINT_AGENT_URL}/status")
            if resp.status_code == 200:
                print_agent_ok = True
    except Exception:
        # En environnement sans print-agent démarré (ex: CI/tests ou dev)
        print_agent_ok = settings.APP_ENV == "test"

    overall_status = "ok" if db_ok else "degraded"
    return HealthReadyResponse(
        status=overall_status,
        database=db_ok,
        print_agent=print_agent_ok,
        fne_queue_length=fne_queue,
    )


# Inclusion de l'API v1
app.include_router(api_v1_router)
