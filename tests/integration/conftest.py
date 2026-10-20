"""Tests d'intégration sur un vrai PostgreSQL.

- `TEST_DATABASE_URL` défini → base existante (CI, conteneur jetable) ;
- sinon → testcontainers démarre un postgres:16-alpine.
Le schéma est créé par les migrations Alembic : les tests valident donc aussi les migrations.
"""

import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.database import get_engine, get_sessionmaker
from caisse.domain.enums import UserRole
from caisse.models import Base, CashRegister, User
from caisse.services import print_terminal_service, user_service
from caisse.services.audit_service import RequestContext

ROOT = Path(__file__).resolve().parents[2]


class FakePrintAgent:
    """Agent d'impression du terminal, simulé par les vraies routes `/print-agent` (jeton de
    terminal) : jamais d'imprimante réelle.

    `printer_online = False` : l'agent rapporte l'imprimante hors ligne ; `fail = True` : il
    prend les travaux mais rend un échec."""

    def __init__(self, client: TestClient, token: str) -> None:
        self.client = client
        self.headers = auth(token)
        self.printer_online = True
        self.fail = False
        self.printed: list[str] = []
        self.drawer_opened_count = 0

    def poll(self) -> dict[str, Any] | None:
        resp = self.client.post(
            "/api/v1/print-agent/poll",
            headers=self.headers,
            json={"printer": {"online": self.printer_online, "paper": "ok", "width": 48}},
        )
        assert resp.status_code == 200, resp.text
        job: dict[str, Any] | None = resp.json()["job"]
        return job

    def report(self, job_id: str, *, printed: bool) -> httpx.Response:
        return self.client.post(
            f"/api/v1/print-agent/jobs/{job_id}/result",
            headers=self.headers,
            json={"printed": printed, "error": None if printed else "plus de papier"},
        )

    def run(self) -> list[dict[str, Any]]:
        """Prend et traite tous les travaux en file, comme la boucle de l'agent."""
        jobs = []
        while (job := self.poll()) is not None:
            jobs.append(job)
            if not self.fail:
                if job["content"]:
                    self.printed.append(job["content"])
                if job["open_drawer"]:
                    self.drawer_opened_count += 1
            resp = self.report(job["id"], printed=not self.fail)
            assert resp.status_code == 204, resp.text
        return jobs


def _clear_caches() -> None:
    get_settings.cache_clear()
    get_engine.cache_clear()
    get_sessionmaker.cache_clear()


@pytest.fixture(scope="session")
def database_url() -> Iterator[str]:
    url = os.environ.get("TEST_DATABASE_URL")
    if url:
        yield url
        return
    from testcontainers.postgres import PostgresContainer

    with PostgresContainer("postgres:16-alpine", driver="psycopg") as pg:
        yield pg.get_connection_url()


@pytest.fixture(scope="session", autouse=True)
def migrated(database_url: str) -> Iterator[None]:
    os.environ["DATABASE_URL"] = database_url
    _clear_caches()
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "alembic"))
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    yield
    get_engine().dispose()


@pytest.fixture(autouse=True)
def clean_tables(migrated: None) -> Iterator[None]:
    yield
    names = ", ".join(t.name for t in Base.metadata.sorted_tables)
    with get_engine().begin() as conn:
        conn.execute(text(f"TRUNCATE {names} CASCADE"))


@pytest.fixture(autouse=True)
def reset_rate_limits() -> Iterator[None]:
    """La suite se connecte bien plus de 10 fois par minute depuis la même « IP »."""
    from caisse.rate_limit import limiter

    limiter.reset()
    yield
    limiter.reset()


@pytest.fixture
def db() -> Iterator[Session]:
    with get_sessionmaker()() as session:
        yield session


@pytest.fixture
def client() -> Iterator[TestClient]:
    from caisse.main import create_app

    with TestClient(create_app()) as c:
        yield c


@pytest.fixture
def print_agent(client: TestClient, db: Session) -> FakePrintAgent:
    """Terminal « Comptoir » et son agent ; sans ce fixture, aucun agent ne s'est signalé et
    les travaux restent `QUEUED`."""
    _, token = print_terminal_service.create_terminal(db, name="Comptoir", actor_id=None, ctx=CTX)
    return FakePrintAgent(client, token)


CTX = RequestContext(device_id="test")


@pytest.fixture
def make_user(db: Session):  # type: ignore[no-untyped-def]
    def _make(pin: str, role: UserRole = UserRole.CAISSIER, name: str | None = None) -> User:
        return user_service.create_user(
            db, full_name=name or f"User {pin}", role=role, pin=pin, actor_id=None, ctx=CTX
        )

    return _make


@pytest.fixture
def make_cash_register(db: Session):  # type: ignore[no-untyped-def]
    def _make(name: str = "Caisse 1") -> CashRegister:
        register = CashRegister(name=name, printer_config={})
        db.add(register)
        db.commit()
        return register

    return _make


def login(client: TestClient, pin: str, device_id: str = "poste-1") -> dict[str, object]:
    resp = client.post("/api/v1/auth/login", json={"pin": pin, "device_id": device_id})
    assert resp.status_code == 200, resp.text
    return resp.json()  # type: ignore[no-any-return]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
