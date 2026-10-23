from fastapi.testclient import TestClient


def test_order_lifecycle(client: TestClient) -> None:
    # 1. Login responsable pour créer catégorie et produit
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    # Créer catégorie et produit
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Plats Chauds", "kind": "FOOD", "sort_order": 1},
    )
    assert cat_res.status_code == 201
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={
            "category_id": cat_id,
            "name": "Thiéboudienne Penda",
            "short_name": "THIEB PENDA",
            "price_xof": 4500,
            "vat_rate": 18.0,
        },
    )
    assert prod_res.status_code == 201
    product_1 = prod_res.json()

    # 2. Login caissière
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Device-Id": "pos-terminal-01",
    }

    # 3. Ouvrir une session de caisse
    open_sess_res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "order-test-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 20000,
            "business_date": "2026-09-28",
        },
    )
    assert open_sess_res.status_code == 201

    # 4. Consulter les tables disponibles
    tables = client.get("/api/v1/tables", headers=headers).json()
    assert len(tables) >= 2
    table_1 = [t for t in tables if t["id"] == "tbl-01"][0]

    # 5. Créer une commande sur Table 1
    create_res = client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "table_id": table_1["id"],
            "guests_count": 3,
        },
    )
    assert create_res.status_code == 201
    order_data = create_res.json()
    order_id = order_data["id"]
    assert order_data["status"] == "OPEN"
    assert order_data["table_id"] == table_1["id"]
    assert order_data["table_label"] == table_1["label"]
    assert order_data["guests_count"] == 3
    assert order_data["total_ttc_xof"] == 0
    assert order_data["due_xof"] == 0
    assert order_data["order_number"].startswith("2026-09-28-")

    # 6. Tentative d'ouvrir une 2e commande sur la même table -> Conflit 409
    conflict_res = client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "table_id": table_1["id"],
            "guests_count": 2,
        },
    )
    assert conflict_res.status_code == 409
    assert conflict_res.json()["code"] == "TABLE_ALREADY_OCCUPIED"

    # 7. Ajouter un produit du catalogue à la commande
    add_item_1_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={
            "product_id": product_1["id"],
            "quantity": 2,
            "note": "Sans piment",
        },
    )
    assert add_item_1_res.status_code == 200
    order_after_item1 = add_item_1_res.json()
    expected_total1 = product_1["price_xof"] * 2
    assert order_after_item1["total_ttc_xof"] == expected_total1
    assert order_after_item1["due_xof"] == expected_total1
    assert len(order_after_item1["items"]) == 1
    item_1 = order_after_item1["items"][0]
    assert item_1["product_name_snapshot"] == product_1["name"]
    assert item_1["unit_price_xof"] == product_1["price_xof"]
    assert item_1["quantity"] == 2
    assert item_1["note"] == "Sans piment"

    # 8. Ajouter un produit personnalisé hors menu
    add_item_2_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={
            "custom_name": "Cocktail Spécial Maison",
            "unit_price_xof": 4000,
            "quantity": 1,
            "note": "Bien frais",
        },
    )
    assert add_item_2_res.status_code == 200
    order_after_item2 = add_item_2_res.json()
    expected_total2 = expected_total1 + 4000
    assert order_after_item2["total_ttc_xof"] == expected_total2
    assert len(order_after_item2["items"]) == 2
    item_2 = [it for it in order_after_item2["items"] if it["product_name_snapshot"] == "Cocktail Spécial Maison"][0]

    # 9. Retirer un produit (soft remove avec motif & traçabilité)
    remove_item_res = client.request(
        "DELETE",
        f"/api/v1/orders/{order_id}/items/{item_2['id']}",
        headers=headers,
        json={"reason": "Client a changé d'avis"},
    )
    assert remove_item_res.status_code == 200
    order_after_remove = remove_item_res.json()
    assert order_after_remove["total_ttc_xof"] == expected_total1
    assert len(order_after_remove["items"]) == 2
    removed_item = [it for it in order_after_remove["items"] if it["id"] == item_2["id"]][0]
    assert removed_item["removed_at"] is not None
    assert removed_item["removal_reason"] == "Client a changé d'avis"

    # 10. Récupérer la commande par ID
    get_res = client.get(f"/api/v1/orders/{order_id}", headers=headers)
    assert get_res.status_code == 200
    assert get_res.json()["id"] == order_id

    # 11. Vérifier l'état de la table sur le tableau de bord de salle
    board_res = client.get("/api/v1/tables/board", headers=headers)
    assert board_res.status_code == 200
    board_data = board_res.json()
    assert board_data["open_orders_count"] >= 1
    table_in_board = [t for t in board_data["tables"] if t["id"] == table_1["id"]][0]
    assert table_in_board["is_occupied"] is True
    assert table_in_board["current_order_id"] == order_id
    assert len(table_in_board["items_summary"]) > 0
    assert table_in_board["items_summary"][0]["quantity"] >= 1
    assert "name" in table_in_board["items_summary"][0]

    # 12. Annuler la commande avec motif
    cancel_res = client.post(
        f"/api/v1/orders/{order_id}/cancel",
        headers=headers,
        json={"reason": "Erreur de saisie / Départ des clients"},
    )
    assert cancel_res.status_code == 200
    cancelled_order = cancel_res.json()
    assert cancelled_order["status"] == "CANCELLED"
    assert cancelled_order["cancelled_reason"] == "Erreur de saisie / Départ des clients"

    # 13. Vérifier que la table est à nouveau libre
    board_res_after = client.get("/api/v1/tables/board", headers=headers)
    table_in_board_after = [t for t in board_res_after.json()["tables"] if t["id"] == table_1["id"]][0]
    assert table_in_board_after["is_occupied"] is False
    assert table_in_board_after["current_order_id"] is None

    # 14. Créer une commande à emporter (table_id = None)
    takeaway_res = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": None, "guests_count": 1},
    )
    assert takeaway_res.status_code == 201
    takeaway_order = takeaway_res.json()
    assert takeaway_order["table_id"] is None
    assert takeaway_order["table_label"] == "Comptoir"

    # 15. Lister les commandes avec filtres
    list_res = client.get("/api/v1/orders", headers=headers)
    orders_data = list_res.json()
    orders_list = orders_data["items"] if isinstance(orders_data, dict) and "items" in orders_data else orders_data
    assert len(orders_list) >= 2
    assert any(o["id"] == order_id for o in orders_list)
    assert any(o["id"] == takeaway_order["id"] for o in orders_list)
