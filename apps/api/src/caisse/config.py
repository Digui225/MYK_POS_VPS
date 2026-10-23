from functools import lru_cache
from typing import Literal
from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    APP_NAME: str = "OsisPos API"
    APP_ENV: Literal["development", "test", "production"] = "development"
    DEBUG: bool = True
    PORT: int = 8001
    HOST: str = "0.0.0.0"
    ALLOWED_HOSTS: list[str] = ["localhost", "127.0.0.1", "testserver"]
    CORS_ORIGINS: list[str] = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:8001",
        "http://127.0.0.1:8001",
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    ]
    ENABLE_DOCS: bool | None = None
    MAX_REQUEST_BODY_SIZE: int = 2 * 1024 * 1024  # 2 Mo par défaut

    # Outbox & Tâches d'arrière-plan
    ENABLE_OUTBOX_WORKER: bool = True
    OUTBOX_WORKER_INTERVAL_SECONDS: float = 30.0

    # Base de données PostgreSQL
    DATABASE_URL: str = "postgresql+psycopg://caisse:caisse_secret@localhost:5432/caisse"

    # Sécurité & Auth
    JWT_SECRET: str = "default_secret_key_to_be_replaced_in_env_with_at_least_64_random_characters"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    REFRESH_TOKEN_EXPIRE_HOURS: int = 12
    PIN_MAX_FAILED_ATTEMPTS: int = 5
    LOCKOUT_DURATION_MINUTES: int = 15

    # Fuseau horaire
    TZ: str = "Africa/Abidjan"

    # Intégrations
    PRINT_AGENT_URL: str = "http://host.docker.internal:8090"
    ENABLE_HARDWARE_PRINTING: bool = False
    FNE_PROVIDER: Literal["manual", "api", "mock"] = "manual"
    FNE_SYNC_TIMEOUT_SECONDS: float = 4.0
    FNE_API_BASE_URL: str = "http://54.247.95.108/ws"
    FNE_API_KEY: str = ""
    FNE_POINT_OF_SALE: str = "CAISSE-1"
    FNE_ESTABLISHMENT: str = "RESTAURANT CHEZ SYLLA PLUS"
    BACKUP_DIR: str = "/var/backups/caisse"

    @property
    def fne_provider(self) -> str:
        return self.FNE_PROVIDER

    @property
    def fne_sync_timeout_seconds(self) -> float:
        return self.FNE_SYNC_TIMEOUT_SECONDS

    @property
    def fne_api_base_url(self) -> str:
        return self.FNE_API_BASE_URL

    @property
    def fne_api_key(self) -> str:
        return self.FNE_API_KEY

    @property
    def fne_verification_base_url(self) -> str:
        if "54.247.95.108" in self.FNE_API_BASE_URL:
            return "http://54.247.95.108/fr/verification"
        return "https://fne.dgi.gouv.ci/verify"

    @property
    def docs_enabled(self) -> bool:
        if self.ENABLE_DOCS is not None:
            return self.ENABLE_DOCS
        return self.APP_ENV != "production"

    @model_validator(mode="after")
    def validate_production_security(self) -> "Settings":
        if self.APP_ENV == "production":
            if self.DEBUG:
                raise ValueError("DEBUG ne doit pas être actif (True) en environnement de production.")
            if (
                self.JWT_SECRET == "default_secret_key_to_be_replaced_in_env_with_at_least_64_random_characters"
                or len(self.JWT_SECRET) < 32
            ):
                raise ValueError(
                    "JWT_SECRET doit être défini avec une clé forte d'au moins 32 caractères en environnement de production."
                )
        return self

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
