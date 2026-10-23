import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.main import app
from caisse.models.user import User
from caisse.security import hash_pin


@pytest.fixture
def admin_token(client: TestClient, db_session: Session) -> str:
    admin = User(
        full_name="Admin Test",
        pin_hash=hash_pin("999999"),
        role="ADMIN",
        is_active=True,
    )
    db_session.add(admin)
    db_session.commit()

    resp = client.post("/api/v1/auth/login", json={"pin": "999999", "device_id": "test-device"})
    assert resp.status_code == 200
    return resp.json()["access_token"]


def test_print_terminal_and_agent_pull_cycle(client: TestClient, admin_token: str):
    headers = {"Authorization": f"Bearer {admin_token}"}

    # 1. Créer un terminal d'impression
    res = client.post(
        "/api/v1/printing/terminals",
        json={"name": "Comptoir Principal"},
        headers=headers,
    )
    assert res.status_code == 201
    data = res.json()
    terminal_id = data["terminal"]["id"]
    token = data["token"]
    assert token.startswith("pt_")

    # 2. Lister les terminaux
    res = client.get("/api/v1/printing/terminals", headers=headers)
    assert res.status_code == 200
    terminals = res.json()
    assert any(t["id"] == terminal_id for t in terminals)

    # 3. Interroger l'agent avec un faux jeton -> 401
    bad_poll = client.post(
        "/api/v1/print-agent/poll",
        headers={"Authorization": "Bearer pt_invalidtoken123"},
        json={"printer": {"online": True, "paper": "ok", "width": 32}},
    )
    assert bad_poll.status_code == 401

    # 4. Interroger l'agent avec le vrai jeton -> 200, aucun travail
    agent_headers = {"Authorization": f"Bearer {token}"}
    poll_1 = client.post(
        "/api/v1/print-agent/poll",
        headers=agent_headers,
        json={"printer": {"online": True, "paper": "ok", "width": 32}},
    )
    assert poll_1.status_code == 200
    assert poll_1.json()["job"] is None

    # Vérifier que le statut de l'imprimante est maintenant "agent_online: true"
    status_res = client.get("/api/v1/printing/status", headers=headers)
    assert status_res.status_code == 200
    assert status_res.json()["agent_online"] is True
    assert status_res.json()["printer_online"] is True

    # 5. Déclencher un travail : ouverture tiroir manuelle
    drawer_res = client.post("/api/v1/printing/open-drawer", headers=headers)
    assert drawer_res.status_code in (200, 202)
    job_id = drawer_res.json()["print_job_id"]

    # 6. L'agent interroge à nouveau -> il reçoit le travail !
    poll_2 = client.post(
        "/api/v1/print-agent/poll",
        headers=agent_headers,
        json={"printer": {"online": True, "paper": "ok", "width": 32}},
    )
    assert poll_2.status_code == 200
    claimed_job = poll_2.json()["job"]
    assert claimed_job is not None
    assert claimed_job["id"] == job_id
    assert claimed_job["type"] == "DRAWER"
    assert claimed_job["open_drawer"] is True

    # Vérifier que le travail est passé en PRINTING
    job_check = client.get(f"/api/v1/printing/jobs/{job_id}", headers=headers)
    assert job_check.status_code == 200
    assert job_check.json()["status"] == "PRINTING"
    assert job_check.json()["attempts"] == 1

    # 7. L'agent confirme que le travail a été exécuté avec succès
    res_report = client.post(
        f"/api/v1/print-agent/jobs/{job_id}/result",
        headers=agent_headers,
        json={"printed": True, "error": None},
    )
    assert res_report.status_code == 204

    # 8. Vérifier que le travail est maintenant DONE
    job_done = client.get(f"/api/v1/printing/jobs/{job_id}", headers=headers)
    assert job_done.status_code == 200
    assert job_done.json()["status"] == "DONE"

    # 9. Révoquer le terminal
    rev_res = client.post(f"/api/v1/printing/terminals/{terminal_id}/revoke", headers=headers)
    assert rev_res.status_code == 200
    assert rev_res.json()["revoked_at"] is not None

    # 10. L'agent révoqué ne peut plus se connecter
    poll_after_revocation = client.post(
        "/api/v1/print-agent/poll",
        headers=agent_headers,
        json={"printer": {"online": True}},
    )
    assert poll_after_revocation.status_code == 401
