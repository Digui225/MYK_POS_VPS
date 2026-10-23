from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse import cli
from caisse.deps import get_fne_provider
from caisse.domain.enums import FneDocumentType, FneStatus, OrderStatus
from caisse.domain.ports import FneUnavailableError, FneUncertainError
from caisse.infrastructure.fne.mock import MockFneProvider
from caisse.models.audit import AuditLog
from caisse.models.fne import FneDocument
from caisse.models.order import Order
from caisse.models.cash_session import CashSession, CashRegister
from caisse.pagination import encode_cursor, decode_cursor
from caisse.services import fne_service


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def test_cursor_encoding_and_decoding():
    now = utcnow()
    row_id = "0192384a-1000-7000-8000-000000000001"
    cursor = encode_cursor(now, row_id)
    assert isinstance(cursor, str)
    assert len(cursor) > 0

    decoded = decode_cursor(cursor)
    assert decoded is not None
    assert decoded.id == row_id
    assert abs((decoded.at - now).total_seconds()) < 0.001

    assert decode_cursor(None) is None
    assert decode_cursor("") is None

    with pytest.raises(Exception):
        decode_cursor("not_a_valid_base64_or_cursor")


def test_orders_keyset_pagination(client: TestClient, db_session: Session):
    # Authenticate as Responsable
    login_res = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_res.status_code == 200
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    # Register & session
    register = db_session.get(CashRegister, "0192384a-3000-7000-8000-000000000001")
    if not register:
        register = CashRegister(
            id="0192384a-3000-7000-8000-000000000001",
            name="Caisse Principale",
            is_active=True,
        )
        db_session.add(register)
        db_session.flush()

    session = CashSession(
        id="0192384a-1000-7000-8000-000000000001",
        cash_register_id=register.id,
        business_date=utcnow().date(),
        opened_by_user_id="usr-resp-01",
        opening_float_xof=10000,
        status="OPEN",
        opened_at=utcnow(),
    )
    db_session.add(session)
    db_session.flush()

    # Seed 5 orders
    now = utcnow()
    for i in range(5):
        order = Order(
            id=f"0192384a-9999-7000-8000-00000000000{i}",
            order_number=f"2026-10-22-{100 + i}",
            cash_session_id=session.id,
            table_id=None,
            note_label=f"Note {i}",
            status="OPEN",
            opened_by_user_id="usr-resp-01",
            guests_count=1,
            total_ttc_xof=1000,
            total_ht_xof=1000,
            total_vat_xof=0,
            paid_xof=0,
            due_xof=1000,
            opened_at=now + timedelta(seconds=i),
        )
        db_session.add(order)
    db_session.commit()

    # Query first page with limit=2
    res1 = client.get("/api/v1/orders?limit=2", headers=headers)
    assert res1.status_code == 200
    page1 = res1.json()
    assert len(page1["items"]) == 2
    assert page1["next_cursor"] is not None

    # Query second page with next_cursor
    res2 = client.get(f"/api/v1/orders?limit=2&cursor={page1['next_cursor']}", headers=headers)
    assert res2.status_code == 200
    page2 = res2.json()
    assert len(page2["items"]) == 2
    assert page2["next_cursor"] is not None

    # Items between pages must not overlap
    page1_ids = {item["id"] for item in page1["items"]}
    page2_ids = {item["id"] for item in page2["items"]}
    assert len(page1_ids.intersection(page2_ids)) == 0

    # Query third page
    res3 = client.get(f"/api/v1/orders?limit=2&cursor={page2['next_cursor']}", headers=headers)
    assert res3.status_code == 200
    page3 = res3.json()
    assert len(page3["items"]) >= 1


def test_fne_worker_retry_next_due(client: TestClient, db_session: Session):
    mock_provider = MockFneProvider()

    # Créer un document en QUEUED déjà échu (sans order_id ou avec order existant)
    doc = FneDocument(
        id="0192384a-8888-7000-8000-000000000001",
        type=FneDocumentType.FNE,
        order_id=None,
        cash_session_id=None,
        customer_id=None,
        template="B2C",
        status=FneStatus.QUEUED,
        is_uncertain=False,
        attempts=1,
        next_retry_at=utcnow() - timedelta(minutes=5),
        payload={
            "request": {
                "client": {"company_name": "CLIENT DIVERS", "phone": "0748735573", "email": "test@myk.ci"},
                "items": [{"name": "Test Plat", "quantity": 1, "amount": 1000, "taxes": ["TVAC"]}],
                "payment_method": "CASH",
            }
        },
        created_by_user_id="usr-resp-01",
    )
    db_session.add(doc)
    db_session.commit()

    # Exécuter retry_next_due
    retried = fne_service.retry_next_due(db_session, mock_provider)
    assert retried is not None
    assert retried.id == doc.id
    db_session.refresh(doc)
    assert doc.status == FneStatus.CERTIFIED
    assert doc.external_number is not None
    assert doc.certified_at is not None

    # Audit log doit avoir device_id == "fne-worker"
    audit = db_session.scalars(
        select(AuditLog).where(AuditLog.action == "fne.submit").order_by(AuditLog.created_at.desc())
    ).first()
    assert audit is not None
    assert audit.device_id == "fne-worker"

    # Aucun autre document échu
    assert fne_service.retry_next_due(db_session, mock_provider) is None


def test_fne_worker_skips_uncertain_documents(client: TestClient, db_session: Session):
    mock_provider = MockFneProvider()

    # Document incertain
    doc = FneDocument(
        id="0192384a-8888-7000-8000-000000000002",
        type=FneDocumentType.FNE,
        order_id=None,
        status=FneStatus.QUEUED,
        is_uncertain=True,  # Incertain !
        attempts=1,
        next_retry_at=utcnow() - timedelta(minutes=5),
        payload={"request": {}},
        created_by_user_id="usr-resp-01",
    )
    db_session.add(doc)
    db_session.commit()

    # Le worker ne doit JAMAIS toucher un document incertain sans résolution préalable
    assert fne_service.retry_next_due(db_session, mock_provider) is None


def test_fne_worker_cli_once(monkeypatch: pytest.MonkeyPatch, db_session: Session):
    mock_provider = MockFneProvider()
    monkeypatch.setattr(cli, "get_fne_provider", lambda: mock_provider)
    monkeypatch.setattr(cli.signal, "signal", lambda *_: None)

    # 2 documents échus
    for i in range(2):
        doc = FneDocument(
            id=f"0192384a-8888-7000-8000-00000000001{i}",
            type=FneDocumentType.FNE,
            status=FneStatus.QUEUED,
            is_uncertain=False,
            attempts=1,
            next_retry_at=utcnow() - timedelta(minutes=10),
            payload={
                "request": {
                    "client": {"company_name": "CLIENT DIVERS", "phone": "0748735573", "email": "test@myk.ci"},
                    "items": [{"name": f"Plat {i}", "quantity": 1, "amount": 2000, "taxes": ["TVAC"]}],
                    "payment_method": "CASH",
                }
            },
            created_by_user_id="usr-resp-01",
        )
        db_session.add(doc)
    db_session.commit()

    # Exécution de cli fne-worker --once
    cli.main(["fne-worker", "--once"])

    # Vérification que les deux ont été certifiés
    for i in range(2):
        d = db_session.get(FneDocument, f"0192384a-8888-7000-8000-00000000001{i}")
        assert d is not None
        assert d.status == FneStatus.CERTIFIED


def test_filter_by_business_date(client: TestClient, db_session: Session):
    login_res = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_res.status_code == 200
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    # Register & session
    register = db_session.get(CashRegister, "0192384a-3000-7000-8000-000000000001")
    if not register:
        register = CashRegister(
            id="0192384a-3000-7000-8000-000000000001",
            name="Caisse Principale",
            is_active=True,
        )
        db_session.add(register)
        db_session.flush()

    sess_date = utcnow().date()
    other_date = sess_date + timedelta(days=1)
    session = CashSession(
        id="0192384a-7777-7000-8000-000000000001",
        cash_register_id=register.id,
        business_date=sess_date,
        opened_by_user_id="usr-resp-01",
        opening_float_xof=10000,
        status="OPEN",
        opened_at=utcnow(),
    )
    db_session.add(session)

    order = Order(
        id="0192384a-7777-7000-8000-000000000002",
        order_number=f"{sess_date.isoformat()}-777",
        cash_session_id=session.id,
        status="PAID",
        opened_by_user_id="usr-resp-01",
        guests_count=1,
        total_ttc_xof=2000,
        total_ht_xof=2000,
        total_vat_xof=0,
        paid_xof=2000,
        due_xof=0,
        opened_at=utcnow(),
    )
    db_session.add(order)

    doc = FneDocument(
        id="0192384a-7777-7000-8000-000000000003",
        type=FneDocumentType.FNE,
        order_id=order.id,
        cash_session_id=session.id,
        status=FneStatus.CERTIFIED,
        external_number="1304777N000777",
        payload={"request": {}, "response": {}},
        created_by_user_id="usr-resp-01",
    )
    db_session.add(doc)
    db_session.commit()

    # Filter FNE documents by matching business_date
    fne_res = client.get(f"/api/v1/fne/documents?business_date={sess_date.isoformat()}", headers=headers)
    assert fne_res.status_code == 200
    doc_ids = [d["id"] for d in fne_res.json()["items"]]
    assert doc.id in doc_ids

    # Filter FNE documents by non-matching business_date
    fne_other_res = client.get(f"/api/v1/fne/documents?business_date={other_date.isoformat()}", headers=headers)
    assert fne_other_res.status_code == 200
    other_doc_ids = [d["id"] for d in fne_other_res.json()["items"]]
    assert doc.id not in other_doc_ids

    # Filter orders by matching business_date
    orders_res = client.get(f"/api/v1/orders?business_date={sess_date.isoformat()}", headers=headers)
    assert orders_res.status_code == 200
    order_ids = [o["id"] for o in orders_res.json()["items"]]
    assert order.id in order_ids

    # Filter orders by non-matching business_date
    orders_other_res = client.get(f"/api/v1/orders?business_date={other_date.isoformat()}", headers=headers)
    assert orders_other_res.status_code == 200
    other_order_ids = [o["id"] for o in orders_other_res.json()["items"]]
    assert order.id not in other_order_ids

