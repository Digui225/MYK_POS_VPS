"""Écran serveur, lot 3 : plan de salle réel.

L'administration place les tables sur le plan de leur zone (grille de 12 colonnes) ;
le plan est renvoyé par la liste des tables et par le plan de salle temps réel.
"""

from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.table import RestaurantTable


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    res = client.post("/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"})
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}


def _place(table_id: str, zone: str, x: int | None, y: int | None, **extra: Any) -> dict[str, Any]:
    return {"table_id": table_id, "zone": zone, "plan_x": x, "plan_y": y, **extra}


def test_new_tables_are_not_placed_yet(client: TestClient) -> None:
    tables = client.get("/api/v1/tables", headers=_headers(client, "123456")).json()
    t1 = next(t for t in tables if t["id"] == "tbl-01")
    assert t1["plan_x"] is None and t1["plan_y"] is None
    assert (t1["plan_w"], t1["plan_h"], t1["shape"]) == (2, 2, "RECT")


def test_admin_saves_the_plan_and_every_screen_sees_it(client: TestClient) -> None:
    admin = _headers(client, "999999")
    res = client.put(
        "/api/v1/tables/plan",
        json={
            "placements": [
                _place("tbl-01", "Salle", 0, 0, plan_w=4, plan_h=2, shape="RECT"),
                _place("tbl-02", "Terrasse", 5, 3, shape="ROUND"),
            ]
        },
        headers=admin,
    )
    assert res.status_code == 200, res.text
    saved = {t["id"]: t for t in res.json()}
    assert (saved["tbl-01"]["plan_x"], saved["tbl-01"]["plan_w"]) == (0, 4)
    assert saved["tbl-02"]["shape"] == "ROUND"

    board = client.get("/api/v1/tables/board", headers=_headers(client, "123456")).json()
    t2 = next(t for t in board["tables"] if t["id"] == "tbl-02")
    assert (t2["zone"], t2["plan_x"], t2["plan_y"], t2["shape"]) == ("Terrasse", 5, 3, "ROUND")


def test_a_table_can_move_to_another_zone_and_leave_the_plan(client: TestClient) -> None:
    admin = _headers(client, "999999")
    client.put("/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Salle", 0, 0)]}, headers=admin)
    res = client.put(
        "/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Terrasse", None, None)]}, headers=admin
    )
    t1 = next(t for t in res.json() if t["id"] == "tbl-01")
    assert (t1["zone"], t1["plan_x"], t1["plan_y"]) == ("Terrasse", None, None)


def test_overlapping_tables_are_refused_and_nothing_is_saved(
    client: TestClient, db_session: Session
) -> None:
    admin = _headers(client, "999999")
    res = client.put(
        "/api/v1/tables/plan",
        json={"placements": [_place("tbl-01", "Salle", 0, 0, plan_w=4), _place("tbl-02", "Salle", 3, 1)]},
        headers=admin,
    )
    assert res.status_code == 409, res.text
    body = res.json()
    assert body["code"] == "TABLE_PLAN_OVERLAP"
    assert "Table T1" in body["detail"] and "Table T2" in body["detail"]

    db_session.expire_all()
    t2 = db_session.get(RestaurantTable, "tbl-02")
    assert t2 is not None and (t2.zone, t2.plan_x) == ("Terrasse", None)


def test_overlap_with_a_table_left_unchanged_is_refused(client: TestClient) -> None:
    admin = _headers(client, "999999")
    ok = client.put("/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Salle", 2, 2)]}, headers=admin)
    assert ok.status_code == 200
    res = client.put(
        "/api/v1/tables/plan", json={"placements": [_place("tbl-02", "Salle", 3, 3)]}, headers=admin
    )
    assert res.status_code == 409 and res.json()["code"] == "TABLE_PLAN_OVERLAP"


def test_inactive_tables_do_not_block_a_place(client: TestClient, db_session: Session) -> None:
    admin = _headers(client, "999999")
    client.put("/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Salle", 0, 0)]}, headers=admin)
    assert client.delete("/api/v1/tables/tbl-01", headers=admin).status_code == 200
    res = client.put(
        "/api/v1/tables/plan", json={"placements": [_place("tbl-02", "Salle", 0, 0)]}, headers=admin
    )
    assert res.status_code == 200, res.text


def test_a_table_cannot_leave_the_grid(client: TestClient) -> None:
    admin = _headers(client, "999999")
    res = client.put(
        "/api/v1/tables/plan",
        json={"placements": [_place("tbl-01", "Salle", 10, 0, plan_w=4)]},
        headers=admin,
    )
    assert res.status_code == 422 and res.json()["code"] == "TABLE_PLAN_OUT_OF_BOUNDS"
    too_far = client.put(
        "/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Salle", 12, 0)]}, headers=admin
    )
    assert too_far.status_code == 422


def test_unknown_or_duplicated_table_is_refused(client: TestClient) -> None:
    admin = _headers(client, "999999")
    unknown = client.put(
        "/api/v1/tables/plan", json={"placements": [_place("tbl-99", "Salle", 0, 0)]}, headers=admin
    )
    assert unknown.status_code == 404 and unknown.json()["code"] == "TABLE_NOT_FOUND"
    twice = client.put(
        "/api/v1/tables/plan",
        json={"placements": [_place("tbl-01", "Salle", 0, 0), _place("tbl-01", "Salle", 4, 0)]},
        headers=admin,
    )
    assert twice.status_code == 422 and twice.json()["code"] == "TABLE_PLAN_DUPLICATE"


def test_only_admin_and_manager_edit_the_plan(client: TestClient) -> None:
    body = {"placements": [_place("tbl-01", "Salle", 0, 0)]}
    assert client.put("/api/v1/tables/plan", json=body, headers=_headers(client, "123456")).status_code == 403
    assert client.put("/api/v1/tables/plan", json=body, headers=_headers(client, "654321")).status_code == 200


def test_changing_zone_from_the_table_form_unplaces_the_table(client: TestClient) -> None:
    admin = _headers(client, "999999")
    client.put("/api/v1/tables/plan", json={"placements": [_place("tbl-01", "Salle", 4, 4)]}, headers=admin)
    same_zone = client.patch("/api/v1/tables/tbl-01", json={"seats": 6}, headers=admin).json()
    assert (same_zone["plan_x"], same_zone["plan_y"]) == (4, 4)
    moved = client.patch("/api/v1/tables/tbl-01", json={"zone": "Terrasse"}, headers=admin).json()
    assert (moved["zone"], moved["plan_x"], moved["plan_y"]) == ("Terrasse", None, None)
