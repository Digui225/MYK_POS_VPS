from fastapi.testclient import TestClient


def test_catalog_lifecycle(client: TestClient) -> None:
    # 1. Login responsable pour la gestion du catalogue
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Device-Id": "pos-terminal-01",
    }

    # 2. Créer une catégorie
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=headers,
        json={
            "name": "Poissons Braisés",
            "kind": "FOOD",
            "sort_order": 1,
            "color": "#f59e0b",
            "fiscal_group": "PLATS",
        },
    )
    assert cat_res.status_code == 201
    cat_data = cat_res.json()
    cat_id = cat_data["id"]
    assert cat_data["name"] == "Poissons Braisés"

    # 3. Créer un produit dans cette catégorie
    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=headers,
        json={
            "category_id": cat_id,
            "name": "Capitaine Braisé Moyen",
            "short_name": "CAPITAINE MOY",
            "price_xof": 6000,
            "vat_rate": 18.0,
            "track_stock": False,
        },
    )
    assert prod_res.status_code == 201
    prod_data = prod_res.json()
    prod_id = prod_data["id"]
    assert prod_data["price_xof"] == 6000

    # 4. Lister les produits (accessible à la caissière également)
    list_res = client.get("/api/v1/catalog/products", headers=headers)
    assert list_res.status_code == 200
    products = list_res.json()
    assert len(products) >= 1
    assert any(p["id"] == prod_id for p in products)

    # 5. Modifier le prix du produit (tracé avec motif)
    price_res = client.patch(
        f"/api/v1/catalog/products/{prod_id}/price",
        headers=headers,
        json={
            "new_price_xof": 6500,
            "reason": "Hausse coût approvisionnement marché",
        },
    )
    assert price_res.status_code == 200
    updated_prod = price_res.json()
    assert updated_prod["price_xof"] == 6500


def test_caissier_cannot_create_category(client: TestClient) -> None:
    # Login caissière (PIN 123456)
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Tentative de création de catégorie -> Refus 403 INSUFFICIENT_PRIVILEGE
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=headers,
        json={
            "name": "Desserts",
            "kind": "OTHER",
        },
    )
    assert cat_res.status_code == 403
    assert cat_res.json()["code"] == "INSUFFICIENT_PRIVILEGE"


def test_normalized_categories_and_products_aliases(client: TestClient) -> None:
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    # 1. Créer une catégorie via /api/v1/categories
    cat_res = client.post(
        "/api/v1/categories",
        headers=headers,
        json={"name": "Grillades Spéciales", "kind": "FOOD"},
    )
    assert cat_res.status_code == 201
    cat_id = cat_res.json()["id"]

    # 2. Lire via /api/v1/categories et via /api/v1/catalog/categories
    res_direct = client.get("/api/v1/categories", headers=headers)
    assert res_direct.status_code == 200
    res_catalog = client.get("/api/v1/catalog/categories", headers=headers)
    assert res_catalog.status_code == 200
    assert any(c["id"] == cat_id for c in res_direct.json())
    assert any(c["id"] == cat_id for c in res_catalog.json())

    # 3. Créer un produit via /api/v1/products
    prod_res = client.post(
        "/api/v1/products",
        headers=headers,
        json={
            "category_id": cat_id,
            "name": "Poulet Braisé Spécial",
            "price_xof": 4500,
        },
    )
    assert prod_res.status_code == 201
    prod_id = prod_res.json()["id"]

    # 4. Lire via /api/v1/products et via /api/v1/catalog/products
    p_direct = client.get(f"/api/v1/products/{prod_id}", headers=headers)
    assert p_direct.status_code == 200
    assert p_direct.json()["name"] == "Poulet Braisé Spécial"

    p_catalog = client.get(f"/api/v1/catalog/products/{prod_id}", headers=headers)
    assert p_catalog.status_code == 200
    assert p_catalog.json()["name"] == "Poulet Braisé Spécial"


def test_static_swagger_docs_available(client: TestClient) -> None:
    res = client.get("/docs")
    assert res.status_code == 200
    assert "/docs/static/swagger-ui-bundle.js" in res.text
    assert "/docs/static/swagger-ui.css" in res.text
