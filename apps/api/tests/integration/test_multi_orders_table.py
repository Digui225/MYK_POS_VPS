from fastapi.testclient import TestClient


def test_shared_table_multi_orders_flow(client: TestClient) -> None:
    # 1. Login responsable pour créer catégorie et produit de test
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Plats Test", "kind": "FOOD", "sort_order": 1},
    )
    assert cat_res.status_code == 201
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={
            "category_id": cat_id,
            "name": "Attiéké Poisson",
            "short_name": "ATTIEKE",
            "price_xof": 3000,
            "vat_rate": 18.0,
        },
    )
    assert prod_res.status_code == 201
    product = prod_res.json()

    # 2. Login caissier
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    assert login_res.status_code == 200
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    # 3. Ouvrir une session de caisse
    open_sess = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "multi-order-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 20000,
            "business_date": "2026-09-28",
        },
    )
    assert open_sess.status_code == 201

    # 4. Ouvrir la 1ère commande (Note 1) sur Table 2
    res_ord1 = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-02", "guests_count": 1},
    )
    assert res_ord1.status_code == 201
    ord1 = res_ord1.json()
    assert ord1["table_id"] == "tbl-02"
    assert ord1["note_label"] == "Note 1"

    # 5. Tentative d'ouvrir une 2e commande sans allow_multiple -> Conflit 409
    res_conflict = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-02", "guests_count": 1},
    )
    assert res_conflict.status_code == 409
    assert res_conflict.json()["code"] == "TABLE_ALREADY_OCCUPIED"

    # 6. Ouvrir la 2e commande avec allow_multiple=True -> 201 Created (Note 2)
    res_ord2 = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-02", "guests_count": 1, "allow_multiple": True},
    )
    assert res_ord2.status_code == 201
    ord2 = res_ord2.json()
    assert ord2["table_id"] == "tbl-02"
    assert ord2["note_label"] == "Note 2"

    # 7. Ouvrir une 3e commande avec libellé explicite
    res_ord3 = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-02", "guests_count": 2, "note_label": "Client C"},
    )
    assert res_ord3.status_code == 201
    ord3 = res_ord3.json()
    assert ord3["note_label"] == "Client C"

    # 8. Ajouter des articles sur Note 1 et Note 2
    client.post(
        f"/api/v1/orders/{ord1['id']}/items",
        headers=headers,
        json={"product_id": product["id"], "quantity": 1},
    )
    client.post(
        f"/api/v1/orders/{ord2['id']}/items",
        headers=headers,
        json={"product_id": product["id"], "quantity": 2},
    )

    # 9. Vérifier le board des tables
    board_res = client.get("/api/v1/tables/board", headers=headers)
    assert board_res.status_code == 200
    board_tables = board_res.json()["tables"]
    board_entry = next(t for t in board_tables if t["id"] == "tbl-02")
    assert board_entry["is_occupied"] is True
    assert board_entry["active_orders_count"] == 3
    assert len(board_entry["active_orders"]) == 3
    labels = [o["note_label"] for o in board_entry["active_orders"]]
    assert "Note 1" in labels
    assert "Note 2" in labels
    assert "Client C" in labels
    # Le total cumulé sur la table doit être (3000 * 1) + (3000 * 2) = 9000 XOF
    assert board_entry["current_total_ttc_xof"] == 9000

    # 10. Régler et solder la Note 1
    ord1_info = client.get(f"/api/v1/orders/{ord1['id']}", headers=headers).json()
    pay_res = client.post(
        f"/api/v1/orders/{ord1['id']}/payments",
        headers={**headers, "Idempotency-Key": "pay-shared-ord1-key"},
        json={
            "method": "CASH",
            "amount_xof": ord1_info["due_xof"],
            "tendered_xof": ord1_info["due_xof"],
        },
    )
    assert pay_res.status_code == 201

    # 11. Vérifier que la table reste occupée avec 2 notes actives
    board_res2 = client.get("/api/v1/tables/board", headers=headers)
    board_entry2 = next(t for t in board_res2.json()["tables"] if t["id"] == "tbl-02")
    assert board_entry2["is_occupied"] is True
    assert board_entry2["active_orders_count"] == 2
    # Le nouveau total restant sur la table est 3000 * 2 = 6000 XOF
    assert board_entry2["current_total_ttc_xof"] == 6000
