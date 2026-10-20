"""Paramètres techniques (pydantic-settings, lus depuis l'environnement / .env).

Les paramètres *métier* (mentions du ticket, TVA, seuils…) vivent dans la table `settings`.
"""

from functools import lru_cache
from typing import Annotated, Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: Literal["development", "test", "production"] = "development"
    database_url: str = "postgresql+psycopg://caisse:caisse@localhost:5432/caisse"

    jwt_secret: str = Field(min_length=32)
    jwt_algorithm: str = "HS256"
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_hours: int = 12
    override_token_ttl_seconds: int = 60
    pin_length: int = 6
    pin_max_attempts: int = 5
    pin_lock_seconds: int = 30

    cors_origins: Annotated[list[str], NoDecode] = []
    # noms d'hôte acceptés (en-tête Host) ; « * » : tous (défaut, l'API est sur le réseau local)
    allowed_hosts: Annotated[list[str], NoDecode] = ["*"]
    # Swagger et /openapi.json : actifs hors production, sauf ENABLE_DOCS explicite
    enable_docs: bool | None = None
    max_request_body_bytes: int = 2 * 1024 * 1024
    # requêtes par minute et par adresse IP (mémoire de chaque processus gunicorn)
    login_rate_limit_per_minute: int = 10
    refresh_rate_limit_per_minute: int = 30

    # l'agent du terminal interroge l'API toutes les ~2 s : au-delà, il est considéré hors ligne
    print_agent_offline_after_seconds: int = 15
    # un travail pris (PRINTING) sans résultat au-delà de ce délai peut être remis en file
    print_job_stale_seconds: int = 120
    printer_width: int = 48
    drawer_pulse: str = "ESC_P_0_25_250"

    fne_provider: Literal["manual", "api", "mock"] = "manual"
    fne_sync_timeout_seconds: float = 4
    fne_api_base_url: str = ""
    fne_api_key: str = ""

    tz: str = "Africa/Abidjan"
    backup_dir: str = "/var/backups/caisse"
    backup_remote_target: str = ""

    @field_validator("cors_origins", "allowed_hosts", mode="before")
    @classmethod
    def _split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [o.strip() for o in value.split(",") if o.strip()]
        return value

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"

    @property
    def docs_enabled(self) -> bool:
        return self.enable_docs if self.enable_docs is not None else not self.is_production


@lru_cache
def get_settings() -> Settings:
    return Settings()
