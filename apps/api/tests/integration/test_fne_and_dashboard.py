from fastapi.testclient import TestClient


def test_customers_crud_and_fne_flow(client: TestClient) -> None:
    # 1. Login responsable pour création catalogue et clients
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    # 2. Créer un client avec NCC DGI
    cust_res = client.post(
        "/api/v1/customers",
        headers=resp_headers,
        json={
            "name": "AFRICA TECH SARL",
            "ncc": "2109876C",
            "phone": "+2250708091011",
            "email": "contact@africatech.ci",
            "address": "Abidjan Plateau Immeuble CCIA",
        },
    )
    assert cust_res.status_code == 201
    cust_data = cust_res.json()
    assert cust_data["name"] == "AFRICA TECH SARL"
    assert cust_data["ncc"] == "2109876C"
    cust_id = cust_data["id"]

    # 3. Tenter de recréer un client avec le même NCC -> 409 Conflict
    dup_res = client.post(
        "/api/v1/customers",
        headers=resp_headers,
        json={"name": "AUTRE SARL", "ncc": "2109876C"},
    )
    assert dup_res.status_code == 409

    # 4. Recherche de client
    search_res = client.get("/api/v1/customers?q=AFRICA", headers=resp_headers)
    assert search_res.status_code == 200
    assert len(search_res.json()) >= 1
    assert search_res.json()[0]["ncc"] == "2109876C"

    # 5. Créer produit
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Spécialités", "kind": "FOOD"},
    )
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Capitaine Braisé", "short_name": "CAPITAINE", "price_xof": 12000},
    )
    prod_id = prod_res.json()["id"]

    # 6. Login caissière pour session et commandes
    cashier_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    cashier_token = cashier_login.json()["access_token"]
    cashier_headers = {"Authorization": f"Bearer {cashier_token}", "X-Device-Id": "pos-terminal-01"}

    # Ouvrir session
    client.post(
        "/api/v1/cash-sessions",
        headers={**cashier_headers, "Idempotency-Key": "sess-fne-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 50000, "business_date": "2026-09-28"},
    )

    # Créer commande
    order_res = client.post(
        "/api/v1/orders",
        headers=cashier_headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    )
    assert order_res.status_code == 201
    order_id = order_res.json()["id"]

    # Ajouter article
    add_item_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=cashier_headers,
        json={"product_id": prod_id, "quantity": 1},
    )
    assert add_item_res.status_code == 200

    # Payer la commande intégralement (12 000 XOF) en encaissement standard (sans FNE demandée)
    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cashier_headers, "Idempotency-Key": "pay-fne-01"},
        json={"method": "CASH", "amount_xof": 12000, "tendered_xof": 15000},
    )
    assert pay_res.status_code == 201
    assert pay_res.json()["order_status"] == "PAID"
    assert pay_res.json()["fne_status"] is None  # Reçu de caisse standard, pas de FNE automatique

    # 7. Génération de la Facture Normalisée à la demande pour l'entreprise
    gen_fne_res = client.post(
        "/api/v1/fne/generate",
        headers=cashier_headers,
        json={"order_id": order_id, "customer_id": cust_id},
    )
    assert gen_fne_res.status_code == 201
    fne_doc_data = gen_fne_res.json()
    assert fne_doc_data["status"] == "CERTIFIED"
    assert fne_doc_data["customer_id"] == cust_id
    assert fne_doc_data["payload"]["buyer"]["ncc"] == "2109876C"

    # 8. Lister les documents FNE (via responsable)
    fne_list = client.get("/api/v1/fne/documents", headers=resp_headers)
    docs_data = fne_list.json()
    docs = docs_data["items"] if isinstance(docs_data, dict) and "items" in docs_data else docs_data
    assert len(docs) >= 1

    # 9. Exporter en CSV
    csv_res = client.get("/api/v1/fne/export", headers=resp_headers)
    assert csv_res.status_code == 200
    assert "text/csv" in csv_res.headers["content-type"]
    assert "Numero_Facture" in csv_res.text

    # 9. Dashboard KPIs
    dash_res = client.get("/api/v1/reports/dashboard?date=2026-09-28", headers=resp_headers)
    assert dash_res.status_code == 200
    dash_data = dash_res.json()
    assert dash_data["business_date"] == "2026-09-28"
    assert dash_data["settled_orders"] >= 1
    assert dash_data["total_sales_ttc_xof"] >= 12000
    assert len(dash_data["payments_by_method"]) >= 1
    assert len(dash_data["top_products"]) >= 1
    assert dash_data["top_products"][0]["product_name"] == "Capitaine Braisé"
