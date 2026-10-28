from datetime import datetime, timezone
import pytest
from sqlalchemy.orm import Session

from caisse.models.outbox import OutboxEvent
from caisse.models.print_job import PrintJob
from caisse.infrastructure.outbox.dispatcher import (
    dispatch_event,
    dispatch_pending_outbox_events,
)


def test_dispatch_pending_outbox_events_empty(db_session: Session) -> None:
    stats = dispatch_pending_outbox_events(db_session)
    assert stats["processed"] == 0
    assert stats["succeeded"] == 0
    assert stats["failed"] == 0


def test_dispatch_print_job_success(db_session: Session) -> None:
    job = PrintJob(
        id="job-test-01",
        job_type="RECEIPT",
        content="Test content",
        open_drawer=False,
        cut=True,
        is_duplicate=False,
        status="QUEUED",
    )
    db_session.add(job)

    event = OutboxEvent(
        id="evt-01",
        event_type="PRINT_JOB",
        aggregate_type="PrintJob",
        aggregate_id="job-test-01",
        payload={"job_id": "job-test-01"},
        status="PENDING",
    )
    db_session.add(event)
    db_session.commit()

    ok = dispatch_event(db_session, event)
    assert ok is True
    assert event.status == "COMPLETED"
    assert event.processed_at is not None
    assert job.status == "DONE"


def test_dispatch_event_failure_backoff(db_session: Session) -> None:
    event = OutboxEvent(
        id="evt-fail-01",
        event_type="FNE_CERTIFICATION",
        aggregate_type="FneDocument",
        aggregate_id="non-existent-fne-doc",
        payload={},
        status="PENDING",
    )
    db_session.add(event)
    db_session.commit()

    ok = dispatch_event(db_session, event)
    assert ok is False
    assert event.status == "PENDING"
    assert event.retry_count == 1
    assert event.next_retry_at is not None
    assert event.last_error is not None


def test_fne_service_has_retry_document_alias() -> None:
    from caisse.services import fne_service

    assert hasattr(fne_service, "retry_document")
    assert fne_service.retry_document is fne_service.retry


def test_dispatch_fne_certification_event(db_session: Session, monkeypatch: pytest.MonkeyPatch) -> None:
    from caisse.models.user import User
    from caisse.models.fne import FneDocument
    from caisse.domain.enums import FneDocumentType, FneStatus
    from caisse.config import get_settings

    # Créer un admin user
    user = User(id="user-admin-1", full_name="Admin", role="ADMIN", pin_hash="dummy")
    db_session.add(user)

    # Document FNE en attente
    fne_doc = FneDocument(
        id="fne-doc-01",
        type=FneDocumentType.FNE,
        status=FneStatus.QUEUED,
        payload={"invoice": {"items": []}},
    )
    db_session.add(fne_doc)

    event = OutboxEvent(
        id="evt-fne-01",
        event_type="FNE_CERTIFICATION",
        aggregate_type="FneDocument",
        aggregate_id="fne-doc-01",
        payload={},
        status="PENDING",
    )
    db_session.add(event)
    db_session.commit()

    settings = get_settings()
    monkeypatch.setattr(settings, "FNE_PROVIDER", "mock")

    ok = dispatch_event(db_session, event)
    assert ok is True
    assert event.status == "COMPLETED"
    assert fne_doc.status == FneStatus.CERTIFIED


def test_dispatch_pending_fne_retries(db_session: Session, monkeypatch: pytest.MonkeyPatch) -> None:
    from caisse.models.user import User
    from caisse.models.fne import FneDocument
    from caisse.domain.enums import FneDocumentType, FneStatus
    from caisse.config import get_settings

    user = User(id="user-admin-2", full_name="Admin", role="ADMIN", pin_hash="dummy")
    db_session.add(user)

    fne_doc = FneDocument(
        id="fne-doc-02",
        type=FneDocumentType.FNE,
        status=FneStatus.QUEUED,
        payload={"invoice": {"items": []}},
    )
    db_session.add(fne_doc)
    db_session.commit()

    settings = get_settings()
    monkeypatch.setattr(settings, "FNE_PROVIDER", "mock")

    stats = dispatch_pending_outbox_events(db_session)
    assert stats["processed"] >= 1
    assert stats["succeeded"] >= 1
    assert fne_doc.status == FneStatus.CERTIFIED


def test_dispatch_leaves_pending_fne_to_the_payment(db_session: Session, monkeypatch: pytest.MonkeyPatch) -> None:
    """Un document PENDING est envoyé par l'encaissement qui l'a créé : le renvoi de fond ne
    doit pas l'envoyer une seconde fois (deux factures DGI pour une vente)."""
    from caisse.models.user import User
    from caisse.models.fne import FneDocument
    from caisse.domain.enums import FneDocumentType, FneStatus
    from caisse.config import get_settings

    db_session.add(User(id="user-admin-3", full_name="Admin", role="ADMIN", pin_hash="dummy"))
    fne_doc = FneDocument(
        id="fne-doc-03",
        type=FneDocumentType.FNE,
        status=FneStatus.PENDING,
        payload={"invoice": {"items": []}},
    )
    db_session.add(fne_doc)
    db_session.commit()
    monkeypatch.setattr(get_settings(), "FNE_PROVIDER", "mock")

    dispatch_pending_outbox_events(db_session)

    assert fne_doc.status == FneStatus.PENDING
    assert fne_doc.attempts == 0


