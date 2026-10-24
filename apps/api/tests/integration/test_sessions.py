from fastapi.testclient import TestClient


def test_session_lifecycle_with_orders_and_z_report(client: TestClient) -> None:
    # 1. Login responsable pour initialiser un produit de démo
    resp_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    ).json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    cat_id = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Grillades Spéciales", "kind": "FOOD"},
    ).json()["id"]

    prod_id = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Mérou Braisé", "short_name": "MEROU BRAISE", "price_xof": 8000},
    ).json()["id"]

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

    # 3. Ouvrir une session de caisse avec 25 000 XOF de fonds
    open_res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "idem-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 25000,
            "business_date": "2026-09-28",
        },
    )
    assert open_res.status_code == 201
    session_data = open_res.json()
    session_id = session_data["id"]
    assert session_data["status"] == "OPEN"
    assert session_data["opening_float_xof"] == 25000

    # 3b. Idempotence ouverture session : rejeu identique -> 200 OK + header Idempotent-Replay
    replay_open_res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "idem-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 25000,
            "business_date": "2026-09-28",
        },
    )
    assert replay_open_res.status_code == 200
    assert replay_open_res.headers.get("Idempotent-Replay") == "true"
    assert replay_open_res.json()["id"] == session_id

    # 3c. Idempotence ouverture session : conflit de corps -> 409 IDEMPOTENCY_CONFLICT
    conflict_open_res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "idem-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 50000,
            "business_date": "2026-09-28",
        },
    )
    assert conflict_open_res.status_code == 409
    assert conflict_open_res.json()["code"] == "IDEMPOTENCY_CONFLICT"

    # 4. Créer une commande de 8 000 XOF
    order_id = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    ).json()["id"]

    client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": prod_id, "quantity": 1},
    )

    # 5. TENTATIVE DE CLÔTURE AVEC COMMANDE OUVERTE -> Échec 409 UNSETTLED_ORDERS_REMAIN
    blocked_close = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": "idem-close-fail"},
        json={"counted_breakdown": {"10000": 2}},
    )
    assert blocked_close.status_code == 409
    assert blocked_close.json()["code"] == "UNSETTLED_ORDERS_REMAIN"

    # 6. Encaisser la commande : 5 000 XOF en espèces et 3 000 XOF en Mobile Money
    client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": "idem-pay-sess-1"},
        json={"method": "CASH", "amount_xof": 5000, "tendered_xof": 5000},
    )
    client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": "idem-pay-sess-2"},
        json={"method": "MOBILE_MONEY", "amount_xof": 3000, "provider": "Wave"},
    )

    # 7. Ajouter un mouvement de sortie de caisse (3 000 XOF pour approvisionnement condiments)
    movement_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/movements",
        headers=headers,
        json={
            "type": "OUT",
            "amount_xof": 3000,
            "reason": "Achat condiments marché",
        },
    )
    assert movement_res.status_code == 201

    # 8. Consulter le rapport X intermédiaire
    # Espèces théoriques : Fonds (25 000) + Ventes Espèces (5 000) - Sorties (3 000) = 27 000 XOF
    x_res = client.get(f"/api/v1/cash-sessions/{session_id}/x-report", headers=headers)
    assert x_res.status_code == 200
    x_data = x_res.json()
    assert x_data["total_sales_ttc_xof"] == 8000
    assert x_data["payments_by_method"]["CASH"] == 5000
    assert x_data["payments_by_method"]["MOBILE_MONEY"] == 3000
    assert x_data["cash_movements_out_xof"] == 3000
    assert x_data["expected_cash_in_drawer_xof"] == 27000
    assert x_data["orders_count"] == 1

    # 9. Clôturer définitivement la session avec comptage exact (27 000 XOF : 2x10000 + 1x5000 + 2x1000)
    close_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": "idem-close-success"},
        json={
            "counted_breakdown": {
                "10000": 2,
                "5000": 1,
                "1000": 2,
            },
            "notes": "Clôture conforme service soir",
        },
    )
    assert close_res.status_code == 200
    close_data = close_res.json()
    assert close_data["status"] == "CLOSED"
    assert close_data["counted_cash_xof"] == 27000
    assert close_data["expected_cash_xof"] == 27000
    assert close_data["variance_xof"] == 0
    assert close_data["z_number"] == 1

    # 9b. Idempotence clôture session : rejeu identique -> 200 OK + header Idempotent-Replay
    replay_close_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": "idem-close-success"},
        json={
            "counted_breakdown": {
                "10000": 2,
                "5000": 1,
                "1000": 2,
            },
            "notes": "Clôture conforme service soir",
        },
    )
    assert replay_close_res.status_code == 200
    assert replay_close_res.headers.get("Idempotent-Replay") == "true"
    assert replay_close_res.json()["id"] == session_id

    # 9c. Idempotence clôture session : conflit de corps -> 409 IDEMPOTENCY_CONFLICT
    conflict_close_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**headers, "Idempotency-Key": "idem-close-success"},
        json={
            "counted_breakdown": {
                "10000": 3,
            },
            "notes": "Autre comptage",
        },
    )
    assert conflict_close_res.status_code == 409
    assert conflict_close_res.json()["code"] == "IDEMPOTENCY_CONFLICT"

    # 10. Consulter le Rapport Z définitif figé
    z_res = client.get(f"/api/v1/cash-sessions/{session_id}/z-report", headers=headers)
    assert z_res.status_code == 200
    z_data = z_res.json()
    assert z_data["z_number"] == 1
    assert z_data["total_sales_ttc_xof"] == 8000
    assert z_data["expected_cash_in_drawer_xof"] == 27000
    assert z_data["counted_cash_xof"] == 27000
    assert z_data["variance_xof"] == 0

    # 11. Imprimer le Rapport Z
    print_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/print-z",
        headers={**headers, "X-Device-Id": "test-device"},
    )
    assert print_res.status_code == 202
    print_data = print_res.json()
    assert print_data["session_id"] == session_id
    assert "print_job_id" in print_data

