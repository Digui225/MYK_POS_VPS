import os
POSTGRES_TEST_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql+psycopg://caisse_user:caisse_pass@127.0.0.1:5441/caisse_test"
)
os.environ["APP_ENV"] = "test"
os.environ["DATABASE_URL"] = POSTGRES_TEST_URL
os.environ["FNE_PROVIDER"] = "mock"

from collections.abc import Generator
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session
from fastapi.testclient import TestClient

from caisse.main import app
from caisse.database import Base, get_db
from caisse.models.user import User
from caisse.models.cash_session import CashRegister
from caisse.security import hash_pin

test_engine = create_engine(
    POSTGRES_TEST_URL,
    pool_pre_ping=True,
)
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=test_engine)


@pytest.fixture(autouse=True)
def disable_hardware_printing_in_tests(monkeypatch: pytest.MonkeyPatch) -> None:
    from caisse.services.printing_service import PrintingService
    monkeypatch.setattr(PrintingService, "_send_raw_esc_pos", lambda *args, **kwargs: True)


@pytest.fixture(autouse=True)
def reset_rate_limiter_in_tests() -> None:
    from caisse.security_rate_limit import login_lockout, rate_limiter
    rate_limiter.reset()
    login_lockout.reset()


@pytest.fixture(scope="function")
def db_session() -> Generator[Session, None, None]:
    Base.metadata.create_all(bind=test_engine)
    db = TestingSessionLocal()

    # Créer les utilisateurs de test
    caissier = User(
        id="usr-caissier-01",
        full_name="Awa Caissière",
        pin_hash=hash_pin("123456"),
        role="CAISSIER",
        is_active=True,
    )
    responsable = User(
        id="usr-resp-01",
        full_name="Kouassi Responsable",
        pin_hash=hash_pin("654321"),
        role="RESPONSABLE",
        is_active=True,
    )
    admin = User(
        id="usr-admin-01",
        full_name="Isaac Admin",
        pin_hash=hash_pin("999999"),
        role="ADMIN",
        is_active=True,
    )
    register = CashRegister(
        id="reg-01",
        name="Caisse Principale",
        is_active=True,
    )
    from caisse.models.table import RestaurantTable

    tbl1 = RestaurantTable(
        id="tbl-01",
        label="Table T1",
        zone="Salle",
        seats=4,
        sort_order=1,
        is_active=True,
    )
    tbl2 = RestaurantTable(
        id="tbl-02",
        label="Table T2",
        zone="Terrasse",
        seats=6,
        sort_order=2,
        is_active=True,
    )
    db.add_all([caissier, responsable, admin, register, tbl1, tbl2])
    db.commit()

    try:
        yield db
    finally:
        db.close()
        Base.metadata.drop_all(bind=test_engine)


@pytest.fixture(scope="function")
def client(db_session: Session) -> Generator[TestClient, None, None]:
    def override_get_db() -> Generator[Session, None, None]:
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()
