"""Recette de l'écran serveur (lot 7) : une journée de service complète, de bout en bout.

L'administration crée les serveurs et place les tables ; la caisse ouvre la journée ; deux
serveurs prennent le service sur leur téléphone (nom puis code), servent des tables (dont
une table partagée), une livraison, envoient en cuisine (bon imprimé à la caisse, sans les
boissons), demandent l'addition ; la caisse encaisse au nom du serveur ; chacun retrouve
son service ; le tableau de bord sépare la livraison.
"""

from datetime import date
from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.print_job import PrintJob

CAISSE = "pos-terminal-01"


def _login(client: TestClient, device: str, **body: Any) -> dict[str, str]:
    res = client.post("/api/v1/auth/login", json={**body, "device_id": device})
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": device}


def _ok(res: Any, status: int = 200) -> Any:
    assert res.status_code == status, res.text
    return res.json()


def _tickets(db: Session, order_id: str) -> list[str]:
    db.expire_all()
    jobs = (
        db.query(PrintJob)
        .filter(PrintJob.order_id == order_id, PrintJob.job_type == "ORDER_TICKET")
        .order_by(PrintJob.created_at)
        .all()
    )
    return [j.content for j in jobs]


def test_une_journee_de_service_en_salle(client: TestClient, db_session: Session) -> None:
    # 1. L'administration : carte, serveurs, plan de salle
    admin = _login(client, CAISSE, pin="999999")
    plats = _ok(client.post("/api/v1/catalog/categories", headers=admin, json={"name": "Plats", "kind": "FOOD"}), 201)
    jus = _ok(client.post("/api/v1/catalog/categories", headers=admin, json={"name": "Jus", "kind": "DRINK"}), 201)

    def product(category: str, name: str, price: int) -> str:
        body = {"category_id": category, "name": name, "price_xof": price}
        return str(_ok(client.post("/api/v1/catalog/products", headers=admin, json=body), 201)["id"])

    foufou = product(plats["id"], "Foufou bœuf", 3500)
    brochet = product(plats["id"], "Plat brochet", 3500)
    bissap = product(jus["id"], "Jus de bissap", 500)
    for name, pin in (("Koffi Yao", "246810"), ("Awa Diallo", "135791")):
        _ok(client.post("/api/v1/users", headers=admin, json={"full_name": name, "role": "SERVEUR", "pin": pin}), 201)
    _ok(
        client.put(
            "/api/v1/tables/plan",
            headers=admin,
            json={"placements": [
                {"table_id": "tbl-01", "zone": "Salle", "plan_x": 0, "plan_y": 0, "shape": "ROUND"},
                {"table_id": "tbl-02", "zone": "Terrasse", "plan_x": 4, "plan_y": 0, "plan_w": 4},
            ]},
        )
    )

    # 2. La caisse ouvre la journée
    caisse = _login(client, CAISSE, pin="123456")
    _ok(
        client.post(
            "/api/v1/cash-sessions",
            headers={**caisse, "Idempotency-Key": "recette-session"},
            json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": date.today().isoformat()},
        ),
        201,
    )

    # 3. Prise de service sur les téléphones : la liste des prénoms, puis le code du compte choisi
    staff = {m["full_name"]: m["id"] for m in _ok(client.get("/api/v1/auth/staff"))}
    assert set(staff) == {"Koffi Yao", "Awa Diallo"}
    koffi = _login(client, "salle-koffi", pin="246810", user_id=staff["Koffi Yao"])
    awa = _login(client, "salle-awa", pin="135791", user_id=staff["Awa Diallo"])
    wrong = client.post(
        "/api/v1/auth/login", json={"pin": "135791", "user_id": staff["Koffi Yao"], "device_id": "salle-koffi"}
    )
    assert wrong.status_code == 401  # le code d'Awa n'ouvre pas le compte de Koffi

    # 4. Koffi ouvre la table 1 (création rejouée après une coupure : une seule note)
    create = {"table_id": "tbl-01", "guests_count": 2, "service_mode": "SUR_PLACE"}
    note = _ok(client.post("/api/v1/orders", headers={**koffi, "Idempotency-Key": "recette-note-t1"}, json=create), 201)
    replay = client.post("/api/v1/orders", headers={**koffi, "Idempotency-Key": "recette-note-t1"}, json=create)
    assert replay.status_code == 200 and replay.json()["id"] == note["id"]

    first = _ok(
        client.post(
            f"/api/v1/orders/{note['id']}/dispatch",
            headers={**koffi, "Idempotency-Key": "recette-envoi-1"},
            json={"items": [
                {"product_id": foufou, "quantity": 1, "seat": 1},
                {"product_id": bissap, "quantity": 2, "seat": 2},
            ]},
        )
    )
    assert (first["dispatch_no"], first["kitchen_lines_count"]) == (1, 1)
    [ticket] = _tickets(db_session, note["id"])
    assert "BON CUISINE" in ticket and "SERVEUR : KOFFI YAO" in ticket.upper()
    assert "FOUFOU" in ticket and "BISSAP" not in ticket and "3500" not in ticket

    # 5. Plan de salle : la table est à Koffi, placée où l'administration l'a mise
    board = {t["id"]: t for t in _ok(client.get("/api/v1/tables/board", headers=awa))["tables"]}
    t1 = board["tbl-01"]
    assert (t1["plan_x"], t1["shape"]) == (0, "ROUND")
    assert t1["active_orders"][0]["served_by_user_id"] == staff["Koffi Yao"]

    # 6. Awa : son propre client à côté (note 2), puis un plat ajouté sur la note de Koffi
    awa_note = _ok(
        client.post("/api/v1/orders", headers=awa, json={"table_id": "tbl-01", "guests_count": 1, "allow_multiple": True}),
        201,
    )
    assert (awa_note["note_label"], awa_note["served_by_name"]) == ("Note 2", "Awa Diallo")
    added = _ok(
        client.post(
            f"/api/v1/orders/{note['id']}/dispatch",
            headers={**awa, "Idempotency-Key": "recette-envoi-awa"},
            json={"items": [{"product_id": brochet}]},
        )
    )
    assert added["order"]["served_by_name"] == "Koffi Yao"  # la note garde son serveur
    assert "*** AJOUT ***" in _tickets(db_session, note["id"])[-1]

    # 7. Koffi : une livraison (comme l'emporter, sans table)
    delivery = _ok(client.post("/api/v1/orders", headers=koffi, json={"service_mode": "LIVRAISON"}), 201)
    _ok(
        client.post(
            f"/api/v1/orders/{delivery['id']}/dispatch",
            headers={**koffi, "Idempotency-Key": "recette-envoi-livraison"},
            json={"items": [{"product_id": brochet}]},
        )
    )
    assert "LIVRAISON" in _tickets(db_session, delivery["id"])[0]

    # 8. Koffi demande l'addition : la caisse le voit sur le plan
    _ok(client.post(f"/api/v1/orders/{note['id']}/bill-request", headers=koffi))
    board = {t["id"]: t for t in _ok(client.get("/api/v1/tables/board", headers=caisse))["tables"]}
    assert board["tbl-01"]["bill_requested"] is True

    # 9. La caisse encaisse ; « remis par » = le serveur de la note. Le serveur n'encaisse pas.
    refused = client.post(
        f"/api/v1/orders/{note['id']}/payments",
        headers={**koffi, "Idempotency-Key": "recette-paiement-serveur"},
        json={"method": "CASH", "amount_xof": 8000},
    )
    assert refused.status_code == 403
    for order_id, amount, key in ((note["id"], 8000, "recette-paiement-t1"), (delivery["id"], 3500, "recette-paiement-liv")):
        paid = _ok(
            client.post(
                f"/api/v1/orders/{order_id}/payments",
                headers={**caisse, "Idempotency-Key": key},
                json={"method": "CASH", "amount_xof": amount, "tendered_xof": amount},
            ),
            201,
        )
        assert paid["payment"]["handed_by_user_id"] == staff["Koffi Yao"]

    # 10. Chacun retrouve son service
    mine = _ok(client.get("/api/v1/salle/my-service", headers=koffi))
    assert (mine["handed_xof"], mine["settled_notes_count"], mine["open_notes"]) == (11500, 2, [])
    kinds = [e["kind"] for e in mine["feed"]]
    assert kinds.count("DISPATCH") == 3 and kinds.count("PAID") == 2 and "BILL_REQUESTED" in kinds
    hers = _ok(client.get("/api/v1/salle/my-service", headers=awa))
    assert (hers["handed_xof"], [n["note_label"] for n in hers["open_notes"]]) == (0, ["Note 2"])

    # 11. La synthèse du jour sépare la livraison de la salle et de l'emporter (commandes réglées)
    manager = _login(client, CAISSE, pin="654321")
    overview = _ok(client.get("/api/v1/reports/overview", headers=manager))
    assert (overview["dine_in_orders"], overview["takeaway_orders"], overview["delivery_orders"]) == (1, 0, 1)
    delivered = _ok(client.get("/api/v1/orders?order_type=DELIVERY", headers=caisse))["items"]
    assert [o["id"] for o in delivered] == [delivery["id"]]
