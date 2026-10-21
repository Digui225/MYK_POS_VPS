from fastapi.testclient import TestClient


def test_complete_e2e_restaurant_service_cycle(client: TestClient) -> None:
    """Scénario E2E complet d'un service restaurant :
    1. Configuration catalogue & Client B2B
    2. Ouverture de session de caisse par la caissière
    3. Prise de commande sur Table
    4. Retrait de ligne supervisé avec Override Manager (PIN + Motif tracé)
    5. Encaissement fractionné / mixte (Mobile Money + Espèces avec rendu de monnaie)
    6. Vérification décrément de stock & génération du job d'impression
    7. Émission de Facture Normalisée Électronique (FNE) B2B certifiée
    8. Consultation du rapport X en temps réel
    9. Clôture irréversible de caisse Z avec comptage des espèces et numéro séquentiel
    10. Export fiscal FNE & Consultation du tableau de bord KPIs direction
    """

    # -------------------------------------------------------------
    # 1. Login Responsable pour initialisation catalogue & client B2B
    # -------------------------------------------------------------
    mgr_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert mgr_login.status_code == 200
    mgr_token = mgr_login.json()["access_token"]
    mgr_headers = {"Authorization": f"Bearer {mgr_token}", "X-Device-Id": "pos-terminal-01"}

    # Création catégorie
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=mgr_headers,
        json={"name": "Grillades & Poissons", "kind": "FOOD", "sort_order": 1},
    )
    assert cat_res.status_code == 201
    cat_id = cat_res.json()["id"]

    # Création produit 1 (Mérou Braisé, avec suivi de stock)
    p1_res = client.post(
        "/api/v1/catalog/products",
        headers=mgr_headers,
        json={
            "category_id": cat_id,
            "name": "Mérou Braisé Royal",
            "short_name": "MEROU BRAISE",
            "price_xof": 15000,
            "vat_rate": 18.0,
            "track_stock": True,
        },
    )
    assert p1_res.status_code == 201
    merou_id = p1_res.json()["id"]

    # Création produit 2 (Bouteille Vin Blanc)
    p2_res = client.post(
        "/api/v1/catalog/products",
        headers=mgr_headers,
        json={
            "category_id": cat_id,
            "name": "Chardonnay Privilège",
            "short_name": "CHARDONNAY",
            "price_xof": 20000,
            "vat_rate": 18.0,
            "track_stock": True,
        },
    )
    assert p2_res.status_code == 201
    vin_id = p2_res.json()["id"]

    # Création des articles de stock correspondants
    art_merou = client.post(
        "/api/v1/stock/articles",
        headers=mgr_headers,
        json={"name": "Mérou Frais", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE", "avg_cost_xof": 8000},
    ).json()
    merou_art_id = art_merou["id"]

    art_vin = client.post(
        "/api/v1/stock/articles",
        headers=mgr_headers,
        json={"name": "Chardonnay Bouteille", "category": "BOISSON", "unit": "bouteille", "out_mode": "RECIPE", "avg_cost_xof": 12000},
    ).json()
    vin_art_id = art_vin["id"]

    # Fiches techniques
    client.put(
        f"/api/v1/products/{merou_id}/components",
        headers=mgr_headers,
        json={"components": [{"article_id": merou_art_id, "quantity": 1.0}]},
    )
    client.put(
        f"/api/v1/products/{vin_id}/components",
        headers=mgr_headers,
        json={"components": [{"article_id": vin_art_id, "quantity": 1.0}]},
    )

    # Approvisionnement initial du stock
    client.post(
        "/api/v1/stock/receipts",
        headers={**mgr_headers, "Idempotency-Key": "rec-e2e-01"},
        json={
            "supplier": "Pêcherie Abidjan",
            "lines": [
                {"article_id": merou_art_id, "quantity": 10.0, "total_cost_xof": 80000},
                {"article_id": vin_art_id, "quantity": 15.0, "total_cost_xof": 180000},
            ],
        },
    )

    # Création client B2B avec NCC
    cust_res = client.post(
        "/api/v1/customers",
        headers=mgr_headers,
        json={
            "name": "SOCIETE COMMERCIALE IVOIRIENNE",
            "ncc": "2104598B",
            "phone": "+2250709080706",
            "email": "compta@sci-ci.com",
            "address": "Abidjan Plateau Tour Postel 2001",
        },
    )
    assert cust_res.status_code == 201
    customer_id = cust_res.json()["id"]

    # -------------------------------------------------------------
    # 2. Login Caissière et Ouverture de la session de caisse
    # -------------------------------------------------------------
    cashier_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    assert cashier_login.status_code == 200
    cashier_token = cashier_login.json()["access_token"]
    cashier_headers = {"Authorization": f"Bearer {cashier_token}", "X-Device-Id": "pos-terminal-01"}

    open_sess = client.post(
        "/api/v1/cash-sessions",
        headers={**cashier_headers, "Idempotency-Key": "e2e-sess-open-01"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 25000,
            "business_date": "2026-09-29",
        },
    )
    assert open_sess.status_code == 201
    session_id = open_sess.json()["id"]
    assert open_sess.json()["status"] == "OPEN"
    assert open_sess.json()["opening_float_xof"] == 25000

    # -------------------------------------------------------------
    # 3. Prise de commande sur Table 2
    # -------------------------------------------------------------
    order_res = client.post(
        "/api/v1/orders",
        headers=cashier_headers,
        json={"table_id": "tbl-02", "guests_count": 4},
    )
    assert order_res.status_code == 201
    order_id = order_res.json()["id"]
    assert order_res.json()["status"] == "OPEN"

    # Ajout 2x Mérou Braisé (2 x 15 000 = 30 000 XOF)
    add1 = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=cashier_headers,
        json={"product_id": merou_id, "quantity": 2, "note": "Bien grillé"},
    )
    assert add1.status_code == 200
    assert add1.json()["total_ttc_xof"] == 30000

    # Ajout 1x Vin Blanc (20 000 XOF) -> Total = 50 000 XOF
    add2 = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=cashier_headers,
        json={"product_id": vin_id, "quantity": 1},
    )
    assert add2.status_code == 200
    assert add2.json()["total_ttc_xof"] == 50000
    assert len(add2.json()["items"]) == 2
    item_vin_id = [it["id"] for it in add2.json()["items"] if it["product_name_snapshot"] == "Chardonnay Privilège"][0]

    # -------------------------------------------------------------
    # 4. Retrait de ligne supervisé avec Manager Override (Motif tracé)
    # -------------------------------------------------------------
    # Le client renonce au vin -> retrait de la bouteille
    override_res = client.post(
        "/api/v1/auth/override",
        headers=cashier_headers,
        json={
            "manager_pin": "654321",
            "reason": "Changement d'avis client avant ouverture",
            "target_action": "REMOVE_ITEM",
        },
    )
    assert override_res.status_code == 200
    override_token = override_res.json()["override_token"]

    rem_res = client.request(
        "DELETE",
        f"/api/v1/orders/{order_id}/items/{item_vin_id}",
        headers={**cashier_headers, "X-Override-Token": override_token},
        json={"reason": "Annulation par client avant service"},
    )
    assert rem_res.status_code == 200
    assert rem_res.json()["total_ttc_xof"] == 30000  # Reste uniquement les 2 mérous (30 000 XOF)

    # -------------------------------------------------------------
    # 5. Encaissement fractionné / mixte (Mobile Money + Espèces)
    # -------------------------------------------------------------
    # Paiement 1 : 10 000 XOF par Wave / Mobile Money
    pay1 = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cashier_headers, "Idempotency-Key": "e2e-pay-mix-01"},
        json={
            "method": "MOBILE_MONEY",
            "amount_xof": 10000,
            "provider": "WAVE",
            "reference": "TXN-WAVE-87654",
        },
    )
    assert pay1.status_code == 201
    assert pay1.json()["order_status"] == "PARTIALLY_PAID"
    assert pay1.json()["remaining_due_xof"] == 20000

    # Paiement 2 : Solde restant 20 000 XOF en CASH (client donne 25 000 XOF -> monnaie 5 000 XOF)
    pay2 = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cashier_headers, "Idempotency-Key": "e2e-pay-mix-02"},
        json={
            "method": "CASH",
            "amount_xof": 20000,
            "tendered_xof": 25000,
        },
    )
    assert pay2.status_code == 201
    pay2_data = pay2.json()
    assert pay2_data["order_status"] == "PAID"
    assert pay2_data["remaining_due_xof"] == 0
    assert pay2_data["change_xof"] == 5000
    assert pay2_data["drawer_opened"] is True
    assert pay2_data["print_job_id"] is not None

    # -------------------------------------------------------------
    # 6. Vérification du décrément automatique de stock
    # -------------------------------------------------------------
    merou_stock = client.get(f"/api/v1/stock/articles/{merou_art_id}", headers=mgr_headers).json()
    assert merou_stock["quantity"] == 8.0  # 10 initial - 2 vendus = 8

    # -------------------------------------------------------------
    # 7. Émission de Facture Normalisée Électronique (FNE) B2B
    # -------------------------------------------------------------
    fne_res = client.post(
        "/api/v1/fne/generate",
        headers=cashier_headers,
        json={"order_id": order_id, "customer_id": customer_id},
    )
    assert fne_res.status_code == 201
    fne_data = fne_res.json()
    assert fne_data["status"] == "CERTIFIED"
    assert fne_data["invoice_number"] is not None
    assert fne_data["payload"]["buyer"]["ncc"] == "2104598B"

    assert fne_data["payload"]["totals"]["total_ttc_xof"] == 30000
    assert fne_data["qr_url"] is not None
    assert fne_data["fne_token"] is not None

    # -------------------------------------------------------------
    # 8. Consultation du rapport X en cours de session (temps réel)
    # -------------------------------------------------------------
    x_rep = client.get(f"/api/v1/cash-sessions/{session_id}/x-report", headers=cashier_headers)
    assert x_rep.status_code == 200
    x_data = x_rep.json()
    assert x_data["total_sales_ttc_xof"] == 30000
    assert x_data["expected_cash_in_drawer_xof"] == 45000  # 25 000 (fond) + 20 000 (cash reçu)

    # -------------------------------------------------------------
    # 9. Clôture irréversible de caisse Z avec comptage des espèces
    # -------------------------------------------------------------
    # Comptage physique réel en fin de service : 45 000 XOF (4x 10000 + 1x 5000)
    close_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**cashier_headers, "Idempotency-Key": "e2e-close-session-01"},
        json={
            "counted_breakdown": {"10000": 4, "5000": 1},
            "notes": "Service midi parfait, caisse juste",
        },
    )
    assert close_res.status_code == 200
    z_data = close_res.json()
    assert z_data["status"] == "CLOSED"
    assert z_data["z_number"] is not None
    assert z_data["variance_xof"] == 0

    # Consultation du rapport Z figé
    z_rep = client.get(f"/api/v1/cash-sessions/{session_id}/z-report", headers=cashier_headers)
    assert z_rep.status_code == 200
    assert z_rep.json()["z_number"] == z_data["z_number"]
    assert z_rep.json()["total_sales_ttc_xof"] == 30000

    # -------------------------------------------------------------
    # 10. Export FNE et Tableau de Bord Responsable
    # -------------------------------------------------------------
    csv_fne = client.get("/api/v1/fne/export", headers=mgr_headers)
    assert csv_fne.status_code == 200
    assert "SOCIETE COMMERCIALE IVOIRIENNE" in csv_fne.text
    assert "30000" in csv_fne.text

    dashboard = client.get("/api/v1/reports/dashboard?date=2026-09-29", headers=mgr_headers)
    assert dashboard.status_code == 200
    dash_data = dashboard.json()
    assert dash_data["business_date"] == "2026-09-29"
    assert dash_data["settled_orders"] >= 1
    assert dash_data["total_sales_ttc_xof"] >= 30000
    assert dash_data["fne_certified_count"] >= 1
