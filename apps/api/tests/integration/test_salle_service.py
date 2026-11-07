"""Écran serveur, lot 6 : « Mon service » et la livraison comptée à part.

- le serveur voit l'argent qu'il a remis à la caisse, ses notes en cours (avec celles sans
  table) et le fil de ses envois, demandes d'addition et règlements ;
- la livraison est séparée de l'emporter dans le tableau de bord et l'historique.
"""

from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.models.user import User
from tests.integration.test_salle_dispatch import TEL, _dispatch, _open_note, salle  # noqa: F401


def _pay(client: TestClient, caisse: dict[str, str], order_id: str, amount: int, key: str) -> None:
    res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caisse, "Idempotency-Key": key},
        json={"method": "CASH", "amount_xof": amount, "tendered_xof": amount},
    )
    assert res.status_code == 201, res.text


def test_my_service_shows_handed_money_open_notes_and_the_feed(
    client: TestClient, salle: dict[str, Any]  # noqa: F811
) -> None:
    table = _open_note(client, salle["koffi"], table_id="tbl-01", guests_count=2)
    _dispatch(
        client,
        salle["koffi"],
        table["id"],
        "fil-envoi-1",
        [{"product_id": salle["foufou"]}, {"product_id": salle["bissap"], "quantity": 2}],
    )
    assert client.post(f"/api/v1/orders/{table['id']}/bill-request", headers=salle["koffi"]).status_code == 200
    _pay(client, salle["caisse"], table["id"], 4500, "fil-paiement")

    away = _open_note(client, salle["koffi"], service_mode="LIVRAISON")
    _dispatch(client, salle["koffi"], away["id"], "fil-envoi-2", [{"product_id": salle["brochet"]}])
    _open_note(client, salle["awa"], table_id="tbl-02")  # la note d'Awa n'apparaît pas chez Koffi

    res = client.get("/api/v1/salle/my-service", headers=salle["koffi"])
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["handed_xof"] == 4500
    assert body["settled_notes_count"] == 1
    assert body["open_xof"] == 3500
    assert [(n["service_mode"], n["due_xof"]) for n in body["open_notes"]] == [("LIVRAISON", 3500)]
    assert body["started_at"] is not None

    kinds = [e["kind"] for e in body["feed"]]
    assert kinds.count("DISPATCH") == 2 and "BILL_REQUESTED" in kinds and "PAID" in kinds
    first_dispatch = next(e for e in body["feed"] if e["kind"] == "DISPATCH" and e["order_id"] == table["id"])
    assert (first_dispatch["kitchen_count"], first_dispatch["drinks_count"]) == (1, 2)
    assert first_dispatch["table_label"] == "Table T1"
    paid = next(e for e in body["feed"] if e["kind"] == "PAID")
    assert (paid["amount_xof"], paid["method"]) == (4500, "CASH")
    assert paid["cashier_name"]
    # Du plus récent au plus ancien
    assert [e["at"] for e in body["feed"]] == sorted((e["at"] for e in body["feed"]), reverse=True)

    awa = client.get("/api/v1/salle/my-service", headers=salle["awa"]).json()
    assert awa["handed_xof"] == 0 and len(awa["open_notes"]) == 1 and awa["feed"] == []


def test_my_service_is_for_waiters_only(client: TestClient, salle: dict[str, Any]) -> None:  # noqa: F811
    assert client.get("/api/v1/salle/my-service", headers=salle["caisse"]).status_code == 403


def test_delivery_is_counted_apart_from_takeaway(client: TestClient, salle: dict[str, Any]) -> None:  # noqa: F811
    takeaway = _open_note(client, salle["caisse"], service_mode="EMPORTER")
    delivery = _open_note(client, salle["caisse"], service_mode="LIVRAISON")
    for note, key in ((takeaway, "a"), (delivery, "b")):
        res = client.post(
            f"/api/v1/orders/{note['id']}/items",
            headers={**salle["caisse"], "Idempotency-Key": f"ligne-{key}"},
            json={"product_id": salle["brochet"]},
        )
        assert res.status_code == 200, res.text
        _pay(client, salle["caisse"], note["id"], 3500, f"paiement-{key}")

    kpis = client.get("/api/v1/reports/dashboard", headers=salle["caisse"]).json()
    assert (kpis["takeaway_orders_count"], kpis["delivery_orders_count"]) == (1, 1)

    resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-terminal-01"})
    manager = {"Authorization": f"Bearer {resp.json()['access_token']}"}
    overview = client.get("/api/v1/reports/overview", headers=manager).json()
    assert (overview["takeaway_orders"], overview["delivery_orders"]) == (1, 1)

    def ids(order_type: str) -> set[str]:
        page = client.get(f"/api/v1/orders?order_type={order_type}", headers=salle["caisse"]).json()
        return {o["id"] for o in page["items"]}

    assert ids("DELIVERY") == {delivery["id"]}
    assert ids("TAKEAWAY") == {takeaway["id"]}


def _note_with_three_guests(client: TestClient, salle: dict[str, Any], key: str) -> dict[str, Any]:  # noqa: F811
    note = _open_note(client, salle["koffi"], table_id="tbl-01", guests_count=3)
    res = _dispatch(
        client,
        salle["koffi"],
        note["id"],
        key,
        [
            {"product_id": salle["foufou"], "seat": 1},
            {"product_id": salle["bissap"], "seat": 0},
            {"product_id": salle["brochet"], "seat": 2},
            {"product_id": salle["foufou"], "seat": 3},
        ],
    )
    assert res.status_code == 200, res.text
    return note


def test_split_by_seat_gives_each_guest_a_note(
    client: TestClient, salle: dict[str, Any], db_session: Any  # noqa: F811
) -> None:
    note = _note_with_three_guests(client, salle, "separation-envoi")
    headers = {**salle["koffi"], "Idempotency-Key": "separation-1"}
    res = client.post(f"/api/v1/orders/{note['id']}/split-by-seat", headers=headers)
    assert res.status_code == 200, res.text
    orders = res.json()["orders"]
    assert [o["note_label"] for o in orders] == ["Note 1", "Note 2", "Note 3"]
    assert [o["total_ttc_xof"] for o in orders] == [4000, 3500, 3500]  # le jus pour la table reste au convive 1
    assert [[it["seat"] for it in o["items"]] for o in orders] == [[1, 0], [2], [3]]
    assert all(o["served_by_name"] == "Koffi" for o in orders)

    again = client.post(f"/api/v1/orders/{note['id']}/split-by-seat", headers=headers)
    assert again.status_code == 200 and [o["id"] for o in again.json()["orders"]] == [o["id"] for o in orders]

    board = client.get("/api/v1/tables/board", headers=salle["caisse"]).json()
    t1 = next(t for t in board["tables"] if t["id"] == "tbl-01")
    assert t1["active_orders_count"] == 3 and t1["current_total_ttc_xof"] == 11000

    # Chaque note se règle à part
    _pay(client, salle["caisse"], orders[1]["id"], 3500, "separation-paiement")
    paid = client.get(f"/api/v1/orders/{orders[1]['id']}", headers=salle["caisse"]).json()
    assert paid["status"] == "PAID"


def test_split_is_refused_after_a_payment_or_with_a_single_guest(
    client: TestClient, salle: dict[str, Any]  # noqa: F811
) -> None:
    note = _note_with_three_guests(client, salle, "separation-envoi-2")
    _pay(client, salle["caisse"], note["id"], 1000, "separation-acompte")
    refused = client.post(
        f"/api/v1/orders/{note['id']}/split-by-seat", headers={**salle["koffi"], "Idempotency-Key": "separation-2"}
    )
    assert refused.status_code == 409 and refused.json()["code"] == "ORDER_SPLIT_NOT_ALLOWED"

    alone = _open_note(client, salle["awa"], table_id="tbl-02")
    _dispatch(client, salle["awa"], alone["id"], "separation-envoi-3", [{"product_id": salle["foufou"], "seat": 1}])
    nothing = client.post(
        f"/api/v1/orders/{alone['id']}/split-by-seat", headers={**salle["awa"], "Idempotency-Key": "separation-3"}
    )
    assert nothing.status_code == 422 and nothing.json()["code"] == "ORDER_SPLIT_NOTHING_TO_SPLIT"


def test_only_the_server_of_the_note_asks_or_splits_its_bill(
    client: TestClient, salle: dict[str, Any]  # noqa: F811
) -> None:
    """Sur une même table, chaque serveur demande l'addition de ses clients : un collègue peut
    ajouter sur la note, pas demander ni séparer son addition. La caisse le peut toujours."""
    note = _note_with_three_guests(client, salle, "verrou-envoi")
    added = _dispatch(client, salle["awa"], note["id"], "verrou-ajout-awa", [{"product_id": salle["bissap"]}])
    assert added.status_code == 200, added.text

    asked = client.post(f"/api/v1/orders/{note['id']}/bill-request", headers=salle["awa"])
    assert asked.status_code == 403 and asked.json()["code"] == "ORDER_NOT_YOUR_NOTE"
    split = client.post(
        f"/api/v1/orders/{note['id']}/split-by-seat", headers={**salle["awa"], "Idempotency-Key": "verrou-sep"}
    )
    assert split.status_code == 403 and split.json()["code"] == "ORDER_NOT_YOUR_NOTE"
    assert client.get(f"/api/v1/orders/{note['id']}", headers=salle["caisse"]).json()["bill_requested_at"] is None

    assert client.post(f"/api/v1/orders/{note['id']}/bill-request", headers=salle["koffi"]).status_code == 200
    assert client.post(f"/api/v1/orders/{note['id']}/bill-request", headers=salle["caisse"]).status_code == 200


def test_caisse_closed_the_waiter_sees_it_and_cannot_open_a_note(
    client: TestClient, db_session: Session
) -> None:
    """Caisse fermée : le serveur prend son service, voit que la caisse est fermée (le téléphone
    affiche « Caisse fermée » à la place de la salle) et ne peut ouvrir aucune note."""
    koffi = User(full_name="Koffi", pin_hash=hash_pin("246810"), role="SERVEUR", is_active=True)
    db_session.add(koffi)
    db_session.commit()

    login = client.post("/api/v1/auth/login", json={"pin": "246810", "user_id": koffi.id, "device_id": TEL})
    assert login.status_code == 200, login.text
    assert login.json()["open_session"] is None
    headers = {"Authorization": f"Bearer {login.json()['access_token']}", "X-Device-Id": TEL}

    current = client.get("/api/v1/cash-sessions/current", headers=headers)
    assert current.status_code == 409 and current.json()["code"] == "NO_OPEN_SESSION"

    refused = client.post("/api/v1/orders", headers=headers, json={"table_id": "tbl-01"})
    assert refused.status_code == 409 and refused.json()["code"] == "NO_OPEN_SESSION"


def test_after_closing_my_service_shows_the_last_service(
    client: TestClient, salle: dict[str, Any]  # noqa: F811
) -> None:
    """Caisse clôturée : « Mon service » montre encore ce que le serveur a remis pendant le
    dernier service, et dit que la caisse est fermée."""
    note = _open_note(client, salle["koffi"], table_id="tbl-01")
    _dispatch(client, salle["koffi"], note["id"], "cloture-envoi", [{"product_id": salle["foufou"]}])
    _pay(client, salle["caisse"], note["id"], 3500, "cloture-paiement")
    assert client.get("/api/v1/salle/my-service", headers=salle["koffi"]).json()["caisse_open"] is True

    session_id = client.get("/api/v1/cash-sessions/current", headers=salle["caisse"]).json()["id"]
    closed = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**salle["caisse"], "Idempotency-Key": "cloture-salle"},
        json={"counted_breakdown": {"10000": 2, "2000": 1, "1000": 1, "500": 1}},  # 20 000 + 3 500
    )
    assert closed.status_code == 200, closed.text

    body = client.get("/api/v1/salle/my-service", headers=salle["koffi"]).json()
    assert body["caisse_open"] is False
    assert (body["handed_xof"], body["settled_notes_count"], body["open_notes"]) == (3500, 1, [])
    assert body["business_date"] is not None
    current = client.get("/api/v1/cash-sessions/current", headers=salle["koffi"])
    assert current.status_code == 409 and current.json()["code"] == "NO_OPEN_SESSION"
