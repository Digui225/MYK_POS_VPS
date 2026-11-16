"""Écran serveur, lot 2 : commande en salle, envoi en cuisine, bon cuisine, addition.

- un serveur ouvre une note à son nom, sur une table libre ou à côté de celle d'un collègue ;
- l'envoi enregistre toutes les lignes en une fois et met en file, à la caisse, un bon cuisine
  sans les boissons ; un envoi rejoué (même clé) ne double rien ;
- la demande d'addition et « remis par » suivent le serveur de la note ;
- à emporter et livraison se prennent sans table.
"""

from datetime import date
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.models.catalog import Category, Product
from caisse.models.order import Order, OrderItem
from caisse.models.print_job import PrintJob
from caisse.models.user import User

CAISSE = "pos-terminal-01"
TEL = "telephone-salle-01"


def _bearer(client: TestClient, body: dict[str, Any], device: str) -> dict[str, str]:
    res = client.post("/api/v1/auth/login", json={**body, "device_id": device})
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": device}


@pytest.fixture
def salle(client: TestClient, db_session: Session) -> dict[str, Any]:
    plats = Category(name="Plats", kind="FOOD", sort_order=1)
    jus = Category(name="Jus", kind="DRINK", sort_order=2)
    db_session.add_all([plats, jus])
    db_session.flush()
    foufou = Product(category_id=plats.id, name="Foufou bœuf", short_name="FOUFOU", price_xof=3500)
    brochet = Product(category_id=plats.id, name="Plat brochet", short_name="BROCHET", price_xof=3500)
    bissap = Product(category_id=jus.id, name="Jus de bissap", short_name="BISSAP", price_xof=500)
    koffi = User(full_name="Koffi", pin_hash=hash_pin("246810"), role="SERVEUR", is_active=True)
    awa = User(full_name="Awa", pin_hash=hash_pin("135791"), role="SERVEUR", is_active=True)
    db_session.add_all([foufou, brochet, bissap, koffi, awa])
    db_session.commit()

    caisse = _bearer(client, {"pin": "123456"}, CAISSE)
    opened = client.post(
        "/api/v1/cash-sessions",
        headers={**caisse, "Idempotency-Key": "salle-session-001"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": date.today().isoformat()},
    )
    assert opened.status_code == 201, opened.text
    return {
        "caisse": caisse,
        "koffi": _bearer(client, {"pin": "246810", "user_id": koffi.id}, TEL),
        "awa": _bearer(client, {"pin": "135791", "user_id": awa.id}, "telephone-salle-02"),
        "koffi_id": koffi.id,
        "awa_id": awa.id,
        "foufou": foufou.id,
        "brochet": brochet.id,
        "bissap": bissap.id,
    }


def _open_note(client: TestClient, headers: dict[str, str], **body: Any) -> dict[str, Any]:
    res = client.post("/api/v1/orders", headers=headers, json=body)
    assert res.status_code == 201, res.text
    return dict(res.json())


def _dispatch(client: TestClient, headers: dict[str, str], order_id: str, key: str, items: list[dict[str, Any]]):
    return client.post(
        f"/api/v1/orders/{order_id}/dispatch",
        headers={**headers, "Idempotency-Key": key},
        json={"items": items},
    )


def _kitchen_jobs(db_session: Session, order_id: str) -> list[PrintJob]:
    db_session.expire_all()
    return (
        db_session.query(PrintJob)
        .filter(PrintJob.order_id == order_id, PrintJob.job_type == "ORDER_TICKET")
        .order_by(PrintJob.created_at)
        .all()
    )


def test_waiter_opens_a_note_in_his_name(client: TestClient, salle: dict[str, Any]) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01", guests_count=4)
    assert note["service_mode"] == "SUR_PLACE"
    assert note["served_by_user_id"] == salle["koffi_id"]
    assert note["served_by_name"] == "Koffi"
    assert note["dispatch_count"] == 0


def test_two_waiters_two_notes_on_one_table(client: TestClient, salle: dict[str, Any]) -> None:
    """Deux clients qui ne sont pas ensemble : chaque serveur a sa note, son addition."""
    _open_note(client, salle["awa"], table_id="tbl-01", guests_count=2)
    occupied = client.post("/api/v1/orders", headers=salle["koffi"], json={"table_id": "tbl-01"})
    assert occupied.status_code == 409
    assert occupied.json()["code"] == "TABLE_ALREADY_OCCUPIED"

    mine = _open_note(client, salle["koffi"], table_id="tbl-01", allow_multiple=True)
    assert mine["note_label"] == "Note 2"
    assert mine["served_by_name"] == "Koffi"

    board = client.get("/api/v1/tables/board", headers=salle["caisse"]).json()
    table = next(t for t in board["tables"] if t["id"] == "tbl-01")
    assert [o["server_name"] for o in table["active_orders"]] == ["Awa", "Koffi"]


def test_dispatch_prints_a_kitchen_ticket_without_drinks(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01", guests_count=4)
    res = _dispatch(
        client,
        salle["koffi"],
        note["id"],
        "envoi-001",
        [
            {"product_id": salle["foufou"], "quantity": 1, "seat": 2},
            {"product_id": salle["bissap"], "quantity": 2, "seat": 1},
            {"product_id": salle["brochet"], "quantity": 1, "seat": 0},
        ],
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["dispatch_no"] == 1
    assert body["kitchen_lines_count"] == 2
    order = body["order"]
    assert order["dispatch_count"] == 1
    assert order["total_ttc_xof"] == 3500 + 2 * 500 + 3500
    assert {(it["product_name_snapshot"], it["seat"], it["dispatch_no"]) for it in order["items"]} == {
        ("Foufou boeuf", 2, 1),
        ("Jus de bissap", 1, 1),
        ("Plat brochet", 0, 1),
    }

    jobs = _kitchen_jobs(db_session, note["id"])
    assert len(jobs) == 1 and jobs[0].id == body["kitchen_ticket_job_id"]
    ticket = jobs[0].content
    assert "CUISINE" in ticket
    assert "T1 - NOTE 1" in ticket.upper()
    assert "Serveur : KOFFI" in ticket
    assert "1 x FOUFOU BOEUF" in ticket and "> convive 2" in ticket
    assert "1 x PLAT BROCHET" in ticket and "> pour la table" in ticket
    assert "BISSAP" not in ticket  # les boissons restent à la caisse
    assert "3 500" in ticket and "TOTAL ENVOI" in ticket and "7 000 F" in ticket  # prix (D18), sans la boisson
    assert jobs[0].open_drawer is False


def test_replayed_dispatch_doubles_nothing(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    items = [{"product_id": salle["foufou"], "quantity": 1}]
    first = _dispatch(client, salle["koffi"], note["id"], "envoi-rejoue", items)
    again = _dispatch(client, salle["koffi"], note["id"], "envoi-rejoue", items)
    assert first.status_code == again.status_code == 200
    assert again.json() == first.json()

    db_session.expire_all()
    lines = db_session.query(OrderItem).filter(OrderItem.order_id == note["id"]).all()
    assert len(lines) == 1
    assert len(_kitchen_jobs(db_session, note["id"])) == 1

    other_body = _dispatch(client, salle["koffi"], note["id"], "envoi-rejoue", [{"product_id": salle["brochet"]}])
    assert other_body.status_code == 409  # même clé, autre contenu : refusé


def test_dispatch_requires_an_idempotency_key(client: TestClient, salle: dict[str, Any]) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    res = client.post(
        f"/api/v1/orders/{note['id']}/dispatch",
        headers=salle["koffi"],
        json={"items": [{"product_id": salle["foufou"]}]},
    )
    assert res.status_code == 400
    assert res.json()["code"] == "IDEMPOTENCY_KEY_REQUIRED"


def test_failed_dispatch_records_nothing(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    res = _dispatch(
        client,
        salle["koffi"],
        note["id"],
        "envoi-casse",
        [{"product_id": salle["foufou"]}, {"product_id": "produit-inexistant"}],
    )
    assert res.status_code == 404
    db_session.expire_all()
    assert db_session.query(OrderItem).filter(OrderItem.order_id == note["id"]).count() == 0
    assert _kitchen_jobs(db_session, note["id"]) == []
    assert db_session.get(Order, note["id"]).dispatch_count == 0  # type: ignore[union-attr]


def test_second_dispatch_is_an_addition(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    _dispatch(client, salle["koffi"], note["id"], "envoi-a", [{"product_id": salle["brochet"]}])
    second = _dispatch(client, salle["koffi"], note["id"], "envoi-b", [{"product_id": salle["foufou"]}])
    assert second.json()["dispatch_no"] == 2

    jobs = _kitchen_jobs(db_session, note["id"])
    assert len(jobs) == 2
    assert "ENVOI 2" in jobs[1].content and "*** AJOUT ***" in jobs[1].content
    assert "1 x PLAT BROCHET" not in jobs[1].content  # le bon ne reprend que l'ajout
    assert "Déjà envoyé" in jobs[1].content and "1 Plat brochet" in jobs[1].content  # rappel
    assert "Total note" in jobs[1].content and "7 000 F" in jobs[1].content


def test_drinks_only_dispatch_prints_no_ticket(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    res = _dispatch(client, salle["koffi"], note["id"], "envoi-boissons", [{"product_id": salle["bissap"], "quantity": 3}])
    assert res.status_code == 200
    assert res.json()["kitchen_lines_count"] == 0
    assert res.json()["kitchen_ticket_job_id"] is None
    assert _kitchen_jobs(db_session, note["id"]) == []


def test_colleague_can_add_to_a_note_which_keeps_its_waiter(
    client: TestClient, db_session: Session, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["awa"], table_id="tbl-01")
    res = _dispatch(client, salle["koffi"], note["id"], "envoi-collegue", [{"product_id": salle["foufou"]}])
    assert res.status_code == 200
    assert res.json()["order"]["served_by_name"] == "Awa"
    assert "Serveur : AWA" in _kitchen_jobs(db_session, note["id"])[0].content


def test_bill_request_shows_on_the_floor_and_new_dish_clears_it(
    client: TestClient, salle: dict[str, Any]
) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-02")
    _dispatch(client, salle["koffi"], note["id"], "envoi-addition", [{"product_id": salle["brochet"]}])

    asked = client.post(f"/api/v1/orders/{note['id']}/bill-request", headers=salle["koffi"])
    assert asked.status_code == 200
    assert asked.json()["bill_requested_at"] is not None

    table = next(
        t for t in client.get("/api/v1/tables/board", headers=salle["caisse"]).json()["tables"] if t["id"] == "tbl-02"
    )
    assert table["bill_requested"] is True
    entry = table["active_orders"][0]
    assert entry["server_name"] == "Koffi"
    assert entry["dispatch_count"] == 1 and entry["last_dispatch_at"] is not None

    more = _dispatch(client, salle["koffi"], note["id"], "envoi-apres-addition", [{"product_id": salle["foufou"]}])
    assert more.json()["order"]["bill_requested_at"] is None


def test_payment_is_handed_by_the_waiter_of_the_note(client: TestClient, salle: dict[str, Any]) -> None:
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    _dispatch(client, salle["koffi"], note["id"], "envoi-paiement", [{"product_id": salle["brochet"]}])

    # Le serveur n'encaisse pas : c'est la caisse qui encaisse, au nom du serveur
    refused = client.post(
        f"/api/v1/orders/{note['id']}/payments",
        headers={**salle["koffi"], "Idempotency-Key": "paiement-serveur"},
        json={"method": "CASH", "amount_xof": 3500},
    )
    assert refused.status_code == 403
    paid = client.post(
        f"/api/v1/orders/{note['id']}/payments",
        headers={**salle["caisse"], "Idempotency-Key": "paiement-caisse"},
        json={"method": "CASH", "amount_xof": 3500, "tendered_xof": 5000},
    )
    assert paid.status_code == 201, paid.text
    assert paid.json()["payment"]["handed_by_user_id"] == salle["koffi_id"]


@pytest.mark.parametrize("mode", ["EMPORTER", "LIVRAISON"])
def test_takeaway_and_delivery_without_table(
    client: TestClient, db_session: Session, salle: dict[str, Any], mode: str
) -> None:
    note = _open_note(client, salle["koffi"], service_mode=mode)
    assert note["service_mode"] == mode and note["table_id"] is None
    _dispatch(client, salle["koffi"], note["id"], f"envoi-{mode}", [{"product_id": salle["foufou"]}])
    label = "A EMPORTER" if mode == "EMPORTER" else "LIVRAISON"
    assert label in _kitchen_jobs(db_session, note["id"])[0].content


def test_service_mode_must_match_the_table(client: TestClient, salle: dict[str, Any]) -> None:
    on_table = client.post("/api/v1/orders", headers=salle["koffi"], json={"table_id": "tbl-01", "service_mode": "LIVRAISON"})
    no_table = client.post("/api/v1/orders", headers=salle["koffi"], json={"service_mode": "SUR_PLACE"})
    assert on_table.status_code == no_table.status_code == 422
    assert on_table.json()["code"] == "INVALID_SERVICE_MODE"

    counter = _open_note(client, salle["caisse"])  # caisse, sans table : à emporter comme avant
    assert counter["service_mode"] == "EMPORTER" and counter["served_by_user_id"] is None


def test_best_sellers_rank_paid_sales(client: TestClient, salle: dict[str, Any]) -> None:
    for i, (product, qty) in enumerate([(salle["brochet"], 3), (salle["foufou"], 1)]):
        note = _open_note(client, salle["caisse"])
        _dispatch(client, salle["caisse"], note["id"], f"envoi-vente-{i}", [{"product_id": product, "quantity": qty}])
        paid = client.post(
            f"/api/v1/orders/{note['id']}/payments",
            headers={**salle["caisse"], "Idempotency-Key": f"vente-{i}"},
            json={"method": "CASH", "amount_xof": 3500 * qty, "tendered_xof": 3500 * qty},
        )
        assert paid.status_code == 201, paid.text
    unpaid = _open_note(client, salle["caisse"])
    _dispatch(client, salle["caisse"], unpaid["id"], "envoi-non-regle", [{"product_id": salle["foufou"], "quantity": 9}])

    ranking = client.get("/api/v1/catalog/best-sellers", headers=salle["koffi"])
    assert ranking.status_code == 200
    assert ranking.json() == [
        {"product_id": salle["brochet"], "quantity_sold": 3},
        {"product_id": salle["foufou"], "quantity_sold": 1},
    ]


def test_replayed_note_creation_opens_a_single_note(
    client: TestClient, salle: dict[str, Any], db_session: Session
) -> None:
    """Le téléphone renvoie la création après une coupure du Wi-Fi : une seule note est ouverte."""
    headers = {**salle["koffi"], "Idempotency-Key": "creation-note-rejouee"}
    body = {"table_id": "tbl-02", "guests_count": 3}
    first = client.post("/api/v1/orders", headers=headers, json=body)
    again = client.post("/api/v1/orders", headers=headers, json=body)
    assert first.status_code == 201
    assert again.status_code == 200 and again.headers["Idempotent-Replay"] == "true"
    assert again.json()["id"] == first.json()["id"]
    db_session.expire_all()
    assert db_session.query(Order).filter(Order.table_id == "tbl-02").count() == 1

    changed = client.post("/api/v1/orders", headers=headers, json={**body, "guests_count": 5})
    assert changed.status_code == 409
