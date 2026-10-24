from fastapi.testclient import TestClient


def test_payment_lifecycle_and_idempotency(client: TestClient) -> None:
    # 1. Login responsable pour créer produit de test
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Grillades", "kind": "FOOD"},
    )
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Poulet Braisé Entier", "short_name": "POULET BRAISE", "price_xof": 7000},
    )
    prod_id = prod_res.json()["id"]

    # 2. Login caissière et ouverture de session
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "sess-idem-pay-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 25000, "business_date": "2026-09-28"},
    )

    # 3. Créer une commande de 7 000 XOF sur Table 1
    order_res = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    )
    order_id = order_res.json()["id"]

    client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": prod_id, "quantity": 1},
    )

    # 4. Encaisser en espèces avec rendu de monnaie (Remis 10 000 F sur 7 000 F)
    idem_key_1 = "idem-pay-order-001"
    pay_headers = {**headers, "Idempotency-Key": idem_key_1}
    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers=pay_headers,
        json={
            "method": "CASH",
            "amount_xof": 7000,
            "tendered_xof": 10000,
        },
    )
    assert pay_res.status_code == 201
    pay_data = pay_res.json()
    assert pay_data["order_status"] == "PAID"
    assert pay_data["remaining_due_xof"] == 0
    assert pay_data["change_xof"] == 3000
    assert pay_data["drawer_opened"] is True
    assert pay_data["print_job_id"] is not None

    # 5. Idempotence : Répéter exactement le même appel avec la même clé
    replay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers=pay_headers,
        json={
            "method": "CASH",
            "amount_xof": 7000,
            "tendered_xof": 10000,
        },
    )
    assert replay_res.status_code == 200
    assert replay_res.headers.get("Idempotent-Replay") == "true"
    replay_data = replay_res.json()
    assert replay_data["payment"]["id"] == pay_data["payment"]["id"]
    assert replay_data["change_xof"] == 3000

    # 5b. Idempotence : Même clé mais corps différent -> 409 IDEMPOTENCY_CONFLICT
    conflict_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers=pay_headers,
        json={
            "method": "CASH",
            "amount_xof": 5000,
            "tendered_xof": 5000,
        },
    )
    assert conflict_res.status_code == 409
    assert conflict_res.json()["code"] == "IDEMPOTENCY_CONFLICT"

    # 6. Lister les paiements de la commande
    list_payments_res = client.get(f"/api/v1/orders/{order_id}/payments", headers=headers)
    assert list_payments_res.status_code == 200
    payments_list = list_payments_res.json()
    assert len(payments_list) == 1
    assert payments_list[0]["amount_xof"] == 7000


def test_split_payment_flow(client: TestClient) -> None:
    # 1. Login caissière et création de commande à emporter (10 000 XOF)
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "sess-idem-pay-02"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": "2026-09-28"},
    )

    order_res = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": None, "guests_count": 1},
    )
    order_id = order_res.json()["id"]

    client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"custom_name": "Prestation Traiteur", "unit_price_xof": 10000, "quantity": 1},
    )

    # 2. Premier paiement partiel : Mobile Money (Wave) de 4 000 XOF
    pay1_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": "idem-split-01"},
        json={
            "method": "MOBILE_MONEY",
            "provider": "Wave",
            "amount_xof": 4000,
            "reference": "WAVE-CI-778899",
        },
    )
    assert pay1_res.status_code == 201
    pay1_data = pay1_res.json()
    assert pay1_data["order_status"] == "PARTIALLY_PAID"
    assert pay1_data["remaining_due_xof"] == 6000
    assert pay1_data["drawer_opened"] is False
    assert pay1_data["print_job_id"] is None

    # 3. Deuxième paiement pour solder : Espèces de 6 000 XOF
    pay2_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": "idem-split-02"},
        json={
            "method": "CASH",
            "amount_xof": 6000,
            "tendered_xof": 6000,
        },
    )
    assert pay2_res.status_code == 201
    pay2_data = pay2_res.json()
    assert pay2_data["order_status"] == "PAID"
    assert pay2_data["remaining_due_xof"] == 0
    assert pay2_data["drawer_opened"] is True
    assert pay2_data["print_job_id"] is not None

    # 4. Vérifier les 2 règlements enregistrés
    all_pays = client.get(f"/api/v1/orders/{order_id}/payments", headers=headers).json()
    assert len(all_pays) == 2


def test_printing_reprint_and_manual_drawer(client: TestClient) -> None:
    # 1. Login caissière & responsable
    caissier_token = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-terminal-01"}).json()["access_token"]
    resp_token = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-terminal-01"}).json()["access_token"]

    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-idem-pay-03"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": "2026-09-28"},
    )

    # 2. Créer et solder une commande
    order_res = client.post("/api/v1/orders", headers=caissier_headers, json={"table_id": None, "guests_count": 1})
    order_id = order_res.json()["id"]
    client.post(f"/api/v1/orders/{order_id}/items", headers=caissier_headers, json={"custom_name": "Menu Express", "unit_price_xof": 3000, "quantity": 1})
    client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caissier_headers, "Idempotency-Key": "idem-pay-03"},
        json={"method": "CASH", "amount_xof": 3000, "tendered_xof": 3000},
    )

    # 3. Ré-imprimer un duplicata
    reprint_res = client.post(f"/api/v1/printing/reprint/{order_id}", headers=caissier_headers)
    assert reprint_res.status_code == 202
    assert reprint_res.json()["is_reprint"] is True

    # 4. Statut imprimante
    status_res = client.get("/api/v1/printing/status", headers=caissier_headers)
    assert status_res.status_code == 200

    # 5. Ouverture manuelle tiroir : Caissière interdite (403)
    c_drawer_res = client.post("/api/v1/printing/open-drawer", headers=caissier_headers)
    assert c_drawer_res.status_code == 403

    # 6. Ouverture manuelle tiroir : Responsable autorisé (202 ou 200)
    r_drawer_res = client.post("/api/v1/printing/open-drawer", headers=resp_headers)
    assert r_drawer_res.status_code in (200, 202)


def test_payment_with_fne_direct_certification(client: TestClient) -> None:
    # 1. Login responsable pour créer produit et client B2B
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Plats B2B", "kind": "FOOD"},
    )
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Menu Entreprise", "short_name": "MENU ENT", "price_xof": 16000},
    )
    prod_id = prod_res.json()["id"]

    cust_res = client.post(
        "/api/v1/customers",
        headers=resp_headers,
        json={"name": "CONFEDERATION GENERALE DES ENTREPRISES", "ncc": "1254632A", "phone": "0767639874"},
    )
    cust_id = cust_res.json()["id"]

    # 2. Login caissier et session
    cais_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    cais_token = cais_login.json()["access_token"]
    cais_headers = {"Authorization": f"Bearer {cais_token}", "X-Device-Id": "pos-terminal-01"}

    client.post(
        "/api/v1/cash-sessions",
        headers={**cais_headers, "Idempotency-Key": "sess-idem-pay-fne-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 10000, "business_date": "2026-10-05"},
    )

    # 3. Commande
    order_res = client.post(
        "/api/v1/orders",
        headers=cais_headers,
        json={"table_id": "tbl-01", "guests_count": 1},
    )
    order_id = order_res.json()["id"]

    client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=cais_headers,
        json={"product_id": prod_id, "quantity": 1},
    )

    # 4. Paiement avec request_fne=True et client B2B
    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cais_headers, "Idempotency-Key": "idem-pay-fne-001"},
        json={
            "method": "CASH",
            "amount_xof": 16000,
            "tendered_xof": 16000,
            "request_fne": True,
            "customer_id": cust_id,
        },
    )
    assert pay_res.status_code == 201
    pay_data = pay_res.json()
    assert pay_data["order_status"] == "PAID"
    assert pay_data["remaining_due_xof"] == 0
    # La FNE doit être certifiée directement à l'encaissement !
    assert pay_data["fne_status"] == "CERTIFIED"

    # Vérification que la FNE est bien enregistrée et certifiée
    fne_res = client.get(f"/api/v1/orders/{order_id}/fne", headers=cais_headers)
    assert fne_res.status_code == 200
    fne_doc = fne_res.json()
    assert fne_doc["status"] == "CERTIFIED"
    assert fne_doc["template"] == "B2B"
    assert fne_doc["external_number"] is not None

