import uuid
from datetime import date

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse.domain.enums import UserRole
from caisse.models import CashRegister, CashSession, Order, RestaurantTable
from caisse.security import utcnow
from caisse.seeds.defaults import ensure_defaults
from caisse.seeds.demo import load_demo_menu

from .conftest import FakePrintAgent, auth, login

pytestmark = pytest.mark.integration


def test_health(client: TestClient) -> None:
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/api/v1/health").status_code == 200


def test_ready_reports_db_and_printer(client: TestClient, print_agent: FakePrintAgent) -> None:
    print_agent.poll()
    resp = client.get("/health/ready")
    assert resp.status_code == 200
    body = resp.json()
    assert body["database"] == "ok"
    assert body["printer"]["agent_online"] is True
    assert body["queues"] == {"print_queued": 0, "print_failed": 0, "fne_pending": 0}


def test_ready_survives_offline_printer(client: TestClient) -> None:
    resp = client.get("/health/ready")
    assert resp.status_code == 200  # l'imprimante ne rend jamais l'API indisponible
    assert resp.json()["printer"]["agent_online"] is False


def test_products_with_stock(client: TestClient, db: Session, make_user) -> None:  # type: ignore[no-untyped-def]
    load_demo_menu(db)
    db.commit()
    make_user("111111", UserRole.CAISSIER)
    headers = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    products = client.get("/api/v1/products", headers=headers).json()["items"]
    by_name = {p["name"]: p for p in products}
    assert by_name["Poisson braisé"]["price_xof"] == 3500
    assert by_name["Poisson braisé"]["vat_rate"] == 0.0  # régime TEE
    assert by_name["Poisson braisé"]["stock_quantity"] is None
    assert by_name["Sucrerie 33cl"]["stock_quantity"] == 48.0
    cats = client.get("/api/v1/categories", headers=headers).json()["items"]
    fish = next(c for c in cats if c["name"] == "Poissons")
    filtered = client.get(f"/api/v1/products?category_id={fish['id']}", headers=headers)
    assert {p["category_id"] for p in filtered.json()["items"]} == {fish["id"]}


def _open_session(db: Session, user_id: uuid.UUID) -> CashSession:
    ensure_defaults(db)
    db.flush()
    register = db.query(CashRegister).one()
    session = CashSession(
        cash_register_id=register.id,
        opened_by_user_id=user_id,
        business_date=date(2026, 9, 24),
        opening_float_xof=20000,
        opened_at=utcnow(),
    )
    db.add(session)
    db.flush()
    return session


def test_table_board(client: TestClient, db: Session, make_user) -> None:  # type: ignore[no-untyped-def]
    user = make_user("111111", UserRole.CAISSIER)
    session = _open_session(db, user.id)
    t1, t2 = RestaurantTable(label="1", sort_order=1), RestaurantTable(label="12", sort_order=2)
    db.add_all([t1, t2])
    db.flush()
    db.add(
        Order(
            order_number="2026-09-24-0001",
            business_date=session.business_date,
            cash_session_id=session.id,
            table_id=t2.id,
            opened_by_user_id=user.id,
            guests_count=4,
            total_ttc_xof=12400,
            due_xof=12400,
            opened_at=utcnow(),
        )
    )
    db.commit()

    headers = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    board = client.get("/api/v1/tables/board", headers=headers).json()
    assert board["business_date"] == "2026-09-24"
    assert board["summary"] == {"revenue_today_xof": 0, "orders_count": 0, "open_orders": 1}
    status = {t["label"]: t for t in board["tables"]}
    assert status["1"]["status"] == "FREE" and status["1"]["order"] is None
    assert status["12"]["status"] == "OCCUPIED"
    assert status["12"]["order"]["total_ttc_xof"] == 12400


def test_db_enforces_one_active_session_per_register(db: Session, make_user) -> None:  # type: ignore[no-untyped-def]
    user = make_user("111111")
    _open_session(db, user.id)
    db.commit()
    with pytest.raises(IntegrityError):
        _open_session(db, user.id)
        db.commit()
    db.rollback()


def test_db_allows_shared_table(db: Session, make_user) -> None:  # type: ignore[no-untyped-def]
    """Partage de table (migration 0006) : plusieurs commandes actives sur une table ; c'est
    le service qui décide, sous verrou de la table (test_tables_sharing)."""
    user = make_user("111111")
    session = _open_session(db, user.id)
    table = RestaurantTable(label="5")
    db.add(table)
    db.flush()
    for n in (1, 2):
        db.add(
            Order(
                order_number=f"2026-09-24-000{n}",
                business_date=session.business_date,
                cash_session_id=session.id,
                table_id=table.id,
                opened_by_user_id=user.id,
                opened_at=utcnow(),
            )
        )
    db.commit()


def test_cli_set_vat_rate_updates_default_and_products(db: Session) -> None:
    from decimal import Decimal

    from caisse.cli import main
    from caisse.models import AppSetting, Product

    load_demo_menu(db)
    db.commit()
    main(["set-vat-rate", "18", "--all-products"])
    db.expire_all()
    assert db.get(AppSetting, "vat.default_rate").value == "18.00"  # type: ignore[union-attr]
    assert {p.vat_rate for p in db.query(Product)} == {Decimal("18.00")}
