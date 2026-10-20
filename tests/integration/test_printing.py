"""Impression tirée par l'agent du terminal : file, prise, résultat, rejeu, jeton de terminal
et actions directes (tiroir, test). Ticket au paiement et à la clôture : voir aussi
test_payments.py / test_cash_sessions.py."""

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from caisse.domain.enums import UserRole
from caisse.models import CashRegister, PrintJob, PrintTerminal, Product, RestaurantTable
from caisse.seeds.demo import load_demo_menu
from caisse.services import print_terminal_service

from .conftest import CTX, FakePrintAgent, auth, login

pytestmark = pytest.mark.integration

LONG_AGO = datetime.now(UTC) - timedelta(hours=1)


@pytest.fixture
def setup(client: TestClient, db: Session, make_user, make_cash_register) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    load_demo_menu(db)
    db.add(RestaurantTable(label="1", sort_order=0))
    db.commit()
    make_user("111111", UserRole.CAISSIER)
    make_user("222222", UserRole.RESPONSABLE)
    make_user("333333", UserRole.ADMIN)
    register: CashRegister = make_cash_register()
    cashier = auth(login(client, "111111")["access_token"])  # type: ignore[arg-type]
    manager = auth(login(client, "222222")["access_token"])  # type: ignore[arg-type]
    admin = auth(login(client, "333333")["access_token"])  # type: ignore[arg-type]
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier, "Idempotency-Key": "open"},
        json={"cash_register_id": str(register.id), "opening_float_xof": 20000},
    )
    assert opened.status_code == 201, opened.text
    return {
        "cashier": cashier,
        "manager": manager,
        "admin": admin,
        "products": {p.name: str(p.id) for p in db.scalars(select(Product))},
        "table_id": str(db.scalars(select(RestaurantTable)).one().id),
    }


def _paid_order(client: TestClient, setup: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """(order_id, receipt) d'une commande soldée en espèces."""
    headers, p = setup["cashier"], setup["products"]
    order_id: str = client.post(
        "/api/v1/orders", headers=headers, json={"table_id": setup["table_id"]}
    ).json()["order"]["id"]
    added = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": p["Poisson braisé"], "quantity": 1},
    )
    assert added.status_code == 201, added.text
    pay = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": f"pay-{order_id}"},
        json={"method": "CASH", "amount_xof": 3500, "tendered_xof": 3500},
    )
    assert pay.status_code == 201, pay.text
    return order_id, pay.json()["receipt"]


def _job(client: TestClient, setup: dict[str, Any], job_id: str) -> dict[str, Any]:
    resp = client.get(f"/api/v1/printing/jobs/{job_id}", headers=setup["cashier"])
    assert resp.status_code == 200, resp.text
    job: dict[str, Any] = resp.json()
    return job


def test_status_follows_agent_polls(
    client: TestClient, db: Session, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    before = client.get("/api/v1/printing/status", headers=setup["cashier"]).json()
    assert before["agent_online"] is False
    assert before["agent_last_seen_at"] is None

    print_agent.poll()
    body = client.get("/api/v1/printing/status", headers=setup["cashier"]).json()
    assert (body["agent_online"], body["printer_online"], body["width"]) == (True, True, 48)
    assert body["queued_jobs"] == 0 and body["failed_jobs"] == 0

    db.execute(update(PrintTerminal).values(last_seen_at=LONG_AGO))
    db.commit()
    stale = client.get("/api/v1/printing/status", headers=setup["cashier"]).json()
    assert stale["agent_online"] is False  # silencieux depuis plus de 15 s
    assert stale["agent_last_seen_at"] is not None


def test_receipt_is_queued_then_printed_by_agent(
    client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    order_id, receipt = _paid_order(client, setup)
    assert receipt["status"] == "QUEUED"
    assert receipt["drawer_opened"] is None
    assert _job(client, setup, receipt["print_job_id"])["status"] == "QUEUED"

    jobs = print_agent.run()
    assert [(j["type"], j["open_drawer"], j["cut"]) for j in jobs] == [("RECEIPT", True, True)]
    assert "Poisson braisé" in print_agent.printed[0]
    assert print_agent.drawer_opened_count == 1

    done = _job(client, setup, receipt["print_job_id"])
    assert (done["status"], done["order_id"], done["attempts"]) == ("DONE", order_id, 1)
    assert print_agent.poll() is None


def test_reprint_then_retry(
    client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    order_id, _ = _paid_order(client, setup)
    print_agent.run()

    print_agent.fail = True
    reprint = client.post(f"/api/v1/orders/{order_id}/reprint", headers=setup["cashier"])
    assert reprint.status_code == 200, reprint.text
    [taken] = print_agent.run()
    assert (taken["is_reprint"], taken["open_drawer"]) == (True, False)

    failed = client.get(
        "/api/v1/printing/jobs", headers=setup["cashier"], params={"status": "FAILED"}
    ).json()["items"]
    assert len(failed) == 1
    job_id = failed[0]["id"]
    assert failed[0]["last_error"] == "plus de papier"

    retried = client.post(f"/api/v1/printing/jobs/{job_id}/retry", headers=setup["cashier"])
    assert retried.status_code == 200, retried.text
    assert retried.json()["status"] == "QUEUED"
    queued = client.post(f"/api/v1/printing/jobs/{job_id}/retry", headers=setup["cashier"])
    assert (queued.status_code, queued.json()["code"]) == (409, "PRINT_JOB_NOT_RETRYABLE")

    print_agent.fail = False
    print_agent.run()
    done = _job(client, setup, job_id)
    assert (done["status"], done["attempts"]) == ("DONE", 2)
    again = client.post(f"/api/v1/printing/jobs/{job_id}/retry", headers=setup["cashier"])
    assert again.status_code == 409


def test_reprint_without_prior_receipt(client: TestClient, setup: dict[str, Any]) -> None:
    headers = setup["cashier"]
    order_id = client.post(
        "/api/v1/orders", headers=headers, json={"table_id": setup["table_id"]}
    ).json()["order"]["id"]
    resp = client.post(f"/api/v1/orders/{order_id}/reprint", headers=headers)
    assert resp.status_code == 409
    assert resp.json()["code"] == "NO_RECEIPT_TO_REPRINT"


def test_printer_offline_keeps_jobs_queued(
    client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    _, receipt = _paid_order(client, setup)
    print_agent.printer_online = False
    assert print_agent.poll() is None
    assert _job(client, setup, receipt["print_job_id"])["status"] == "QUEUED"
    status = client.get("/api/v1/printing/status", headers=setup["cashier"]).json()
    assert (status["agent_online"], status["printer_online"]) == (True, False)

    print_agent.printer_online = True
    print_agent.run()
    assert _job(client, setup, receipt["print_job_id"])["status"] == "DONE"
    assert print_agent.drawer_opened_count == 1  # le tiroir s'ouvre même avec du retard


def test_stale_printing_job_can_be_requeued(
    client: TestClient, db: Session, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    _, receipt = _paid_order(client, setup)
    job_id = receipt["print_job_id"]
    claimed = print_agent.poll()  # pris, puis l'agent s'arrête sans rendre de résultat
    assert claimed is not None and claimed["id"] == job_id
    assert _job(client, setup, job_id)["status"] == "PRINTING"

    fresh = client.post(f"/api/v1/printing/jobs/{job_id}/retry", headers=setup["cashier"])
    assert fresh.status_code == 409  # peut-être en train d'imprimer : pas de double ticket

    db.execute(update(PrintJob).where(PrintJob.id == claimed["id"]).values(claimed_at=LONG_AGO))
    db.commit()
    stale = client.post(f"/api/v1/printing/jobs/{job_id}/retry", headers=setup["cashier"])
    assert stale.status_code == 200, stale.text
    assert stale.json()["status"] == "QUEUED"

    late = print_agent.report(job_id, printed=True)  # résultat de l'ancienne prise
    assert (late.status_code, late.json()["code"]) == (409, "PRINT_JOB_NOT_CLAIMED")
    print_agent.run()
    assert _job(client, setup, job_id)["status"] == "DONE"


def test_result_checks_terminal_and_is_idempotent(
    client: TestClient, db: Session, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    _, receipt = _paid_order(client, setup)
    job = print_agent.poll()
    assert job is not None

    _, other_token = print_terminal_service.create_terminal(db, name="Bar", actor_id=None, ctx=CTX)
    other = FakePrintAgent(client, other_token)
    stolen = other.report(job["id"], printed=True)
    assert (stolen.status_code, stolen.json()["code"]) == (409, "PRINT_JOB_NOT_CLAIMED")

    assert print_agent.report(job["id"], printed=True).status_code == 204
    assert print_agent.report(job["id"], printed=True).status_code == 204  # réponse perdue
    flipped = print_agent.report(job["id"], printed=False)
    assert flipped.status_code == 409
    assert _job(client, setup, receipt["print_job_id"])["status"] == "DONE"


def test_agent_routes_require_terminal_token(
    client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    body = {"printer": {"online": True}}
    missing = client.post("/api/v1/print-agent/poll", json=body)
    assert (missing.status_code, missing.json()["code"]) == (401, "TERMINAL_TOKEN_INVALID")
    user_jwt = client.post("/api/v1/print-agent/poll", headers=setup["cashier"], json=body)
    assert user_jwt.status_code == 401

    print_agent.poll()
    [terminal] = client.get("/api/v1/printing/terminals", headers=setup["admin"]).json()["items"]
    revoked = client.post(
        f"/api/v1/printing/terminals/{terminal['id']}/revoke", headers=setup["admin"]
    )
    assert revoked.status_code == 200
    assert revoked.json()["revoked_at"] is not None
    refused = client.post("/api/v1/print-agent/poll", headers=print_agent.headers, json=body)
    assert refused.status_code == 401
    status = client.get("/api/v1/printing/status", headers=setup["cashier"]).json()
    assert status["agent_online"] is False  # un terminal révoqué ne compte plus


def test_terminal_admin(client: TestClient, setup: dict[str, Any]) -> None:
    url = "/api/v1/printing/terminals"
    assert client.get(url, headers=setup["manager"]).status_code == 403
    denied = client.post(url, headers=setup["manager"], json={"name": "Comptoir"})
    assert denied.status_code == 403

    created = client.post(url, headers=setup["admin"], json={"name": "Comptoir"})
    assert created.status_code == 201, created.text
    token = created.json()["token"]
    assert token.startswith("pt_") and len(token) > 40
    assert "token" not in created.json()["terminal"]
    taken = client.post(url, headers=setup["admin"], json={"name": "Comptoir"})
    assert (taken.status_code, taken.json()["code"]) == (409, "PRINT_TERMINAL_NAME_EXISTS")

    agent = FakePrintAgent(client, token)
    assert agent.poll() is None
    [listed] = client.get(url, headers=setup["admin"]).json()["items"]
    assert listed["name"] == "Comptoir" and listed["last_seen_at"] is not None
    assert listed["printer_status"]["online"] is True


def test_open_drawer(
    client: TestClient, db: Session, setup: dict[str, Any], print_agent: FakePrintAgent
) -> None:
    url = "/api/v1/printing/open-drawer"
    denied = client.post(url, headers=setup["cashier"])
    assert denied.status_code == 403

    offline = client.post(url, headers=setup["manager"])
    assert (offline.status_code, offline.json()["code"]) == (503, "PRINT_AGENT_UNAVAILABLE")

    print_agent.printer_online = False
    print_agent.poll()
    broken = client.post(url, headers=setup["manager"])
    assert (broken.status_code, broken.json()["code"]) == (503, "PRINTER_UNAVAILABLE")

    print_agent.printer_online = True
    print_agent.poll()
    resp = client.post(url, headers=setup["manager"])
    assert resp.status_code == 202, resp.text
    assert (resp.json()["type"], resp.json()["status"]) == ("DRAWER", "QUEUED")
    [job] = print_agent.run()
    assert (job["content"], job["open_drawer"], job["cut"]) == ("", True, False)
    assert print_agent.drawer_opened_count == 1 and print_agent.printed == []
    assert _job(client, setup, resp.json()["id"])["status"] == "DONE"

    db.execute(update(PrintTerminal).values(last_seen_at=LONG_AGO))
    db.commit()
    silent = client.post(url, headers=setup["manager"])
    assert silent.status_code == 503  # agent muet : pas de tiroir qui s'ouvre plus tard


def test_test_print(client: TestClient, setup: dict[str, Any], print_agent: FakePrintAgent) -> None:
    denied = client.post("/api/v1/printing/test", headers=setup["manager"])
    assert denied.status_code == 403

    offline = client.post("/api/v1/printing/test", headers=setup["admin"])
    assert (offline.status_code, offline.json()["code"]) == (503, "PRINT_AGENT_UNAVAILABLE")

    print_agent.poll()
    resp = client.post("/api/v1/printing/test", headers=setup["admin"])
    assert resp.status_code == 202, resp.text
    assert resp.json()["type"] == "TEST"
    [job] = print_agent.run()
    assert job["open_drawer"] is False
    assert "TICKET DE TEST" in print_agent.printed[0]
