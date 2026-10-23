from decimal import Decimal
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product
from caisse.models.stock import StockArticle, ProductComponent


def test_production_and_market_purchases_workflow(client: TestClient, db_session: Session) -> None:
    # 1. Authentification
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    caissier_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    assert caissier_login.status_code == 200
    caissier_token = caissier_login.json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}

    # 2. Création de deux articles protéine
    chicken_art = StockArticle(
        name="Poulet Entier",
        category="PROTEINE",
        unit="pièce",
        out_mode="RECIPE",
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("3000"),
    )
    beef_art = StockArticle(
        name="Bœuf Viande",
        category="PROTEINE",
        unit="kg",
        out_mode="RECIPE",
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("4000"),
    )
    db_session.add_all([chicken_art, beef_art])
    db_session.flush()

    # Création des plats vendus au catalogue
    cat = Category(name="Plats Chauds Production", kind="FOOD", sort_order=1)
    db_session.add(cat)
    db_session.flush()

    plat_poulet = Product(
        category_id=cat.id,
        name="Plat Poulet Rôti",
        short_name="Poulet",
        price_xof=3000,
        vat_rate=Decimal("0.00"),
    )
    db_session.add(plat_poulet)
    db_session.flush()

    # Fiche technique : 1 plat = 0.25 poulet (donc 1 poulet = 4 plats)
    comp = ProductComponent(
        product_id=plat_poulet.id,
        article_id=chicken_art.id,
        quantity=Decimal("0.250"),
    )
    db_session.add(comp)
    db_session.commit()

    # 3. La caissière prépare son bon d'achat pour le marché (POST /api/v1/production/market-purchases)
    # 10 poulets à 3000 F et 5 kg de boeuf à 4000 F -> Budget prévu = 30 000 + 20 000 = 50 000 F
    purchase_res = client.post(
        "/api/v1/production/market-purchases",
        headers=caissier_headers,
        json={
            "business_date": "2026-10-19",
            "notes": "Courses du matin Lundi",
            "items": [
                {"article_id": chicken_art.id, "quantity": 10, "unit_price_xof": 3000},
                {"article_id": beef_art.id, "quantity": 5, "unit_price_xof": 4000},
            ],
        },
    )
    assert purchase_res.status_code == 201, purchase_res.text
    purchase_data = purchase_res.json()
    assert purchase_data["status"] == "DRAFT"
    assert purchase_data["total_budget_xof"] == 50000
    assert len(purchase_data["items"]) == 2
    purchase_id = purchase_data["id"]

    # 4. Consultation du détail
    get_res = client.get(
        f"/api/v1/production/market-purchases/{purchase_id}",
        headers=caissier_headers,
    )
    assert get_res.status_code == 200
    assert get_res.json()["total_budget_xof"] == 50000

    # 5. Validation par le responsable après retour du marché
    comp_res = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/complete",
        headers=resp_headers,
    )
    assert comp_res.status_code == 200
    assert comp_res.json()["status"] == "COMPLETED"

    # Vérification que le stock a été mis à jour
    db_session.refresh(chicken_art)
    db_session.refresh(beef_art)
    assert chicken_art.quantity == Decimal("10")
    assert beef_art.quantity == Decimal("5")

    # 6. Enregistrement de la sortie cuisine le matin (DailyPreparation)
    # Le cuisinier sort 3 poulets avec un rendement de 4 plats/poulet -> 12 plats prévus
    prep_res = client.post(
        "/api/v1/production/daily-preparations",
        headers=caissier_headers,
        json={
            "business_date": "2026-10-19",
            "article_id": chicken_art.id,
            "prepared_quantity": 3,
            "yield_portions_per_unit": 4,
            "notes": "3 poulets sortis pour le midi",
        },
    )
    assert prep_res.status_code == 200, prep_res.text
    prep_data = prep_res.json()
    assert prep_data["prepared_quantity"] == 3.0
    assert prep_data["theoretical_dishes"] == 12

    # 7. Consultation de la matrice hebdomadaire
    matrix_res = client.get(
        "/api/v1/production/weekly-matrix?date_from=2026-10-19&date_to=2026-10-23",
        headers=resp_headers,
    )
    assert matrix_res.status_code == 200, matrix_res.text
    matrix_data = matrix_res.json()
    assert matrix_data["date_from"] == "2026-10-19"
    assert matrix_data["date_to"] == "2026-10-23"
    assert matrix_data["total_weekly_purchases_xof"] == 50000

    chicken_row = next((r for r in matrix_data["rows"] if r["article_id"] == chicken_art.id), None)
    assert chicken_row is not None
    assert chicken_row["weekly_purchased_qty"] == 10.0
    assert chicken_row["weekly_purchased_cost_xof"] == 30000
    assert chicken_row["default_yield_portions"] == 4.0
    assert chicken_row["weekly_potential_dishes"] == 40
    assert chicken_row["purchase_unit_price_xof"] == 3000  # 30000 / 10
    assert chicken_row["dish_selling_price_xof"] == 3000  # Plat poulet
    assert chicken_row["weekly_expected_revenue_xof"] == 120000  # 40 * 3000
    assert chicken_row["expected_margin_pct"] == 75.0  # (120000 - 30000) / 120000 * 100 = 75%

    # Lundi : 3 poulets sortis -> 12 plats prévus -> 0 vendus (pour le moment) -> Écart = -12
    lundi_data = next((d for d in chicken_row["days"] if d["business_date"] == "2026-10-19"), None)
    assert lundi_data is not None
    assert lundi_data["remaining_quantity"] == 10.0  # stock avant sortie
    assert lundi_data["prepared_quantity"] == 3.0
    assert lundi_data["suggested_quantity"] == 0.0  # car 0 vendu
    assert lundi_data["theoretical_dishes"] == 12
    assert lundi_data["sold_dishes"] == 0
    assert lundi_data["variance_dishes"] == -12
    assert lundi_data["financial_impact_xof"] == 12 * 3000  # 36 000 FCFA
    assert lundi_data["expected_revenue_xof"] == 36000  # 12 * 3000

    # 8. Tests des cas d'erreur 404
    # Achat avec article inexistant
    bad_purchase = client.post(
        "/api/v1/production/market-purchases",
        headers=caissier_headers,
        json={
            "business_date": "2026-10-19",
            "items": [{"article_id": "00000000-0000-0000-0000-000000000000", "quantity": 1, "unit_price_xof": 1000}],
        },
    )
    assert bad_purchase.status_code == 404
    assert bad_purchase.json()["code"] == "ARTICLE_NOT_FOUND"

    # Consultation bon inexistant
    bad_get = client.get(
        "/api/v1/production/market-purchases/00000000-0000-0000-0000-000000000000",
        headers=caissier_headers,
    )
    assert bad_get.status_code == 404
    assert bad_get.json()["code"] == "PURCHASE_NOT_FOUND"

    # Validation bon inexistant
    bad_complete = client.post(
        "/api/v1/production/market-purchases/00000000-0000-0000-0000-000000000000/complete",
        headers=resp_headers,
    )
    assert bad_complete.status_code == 404
    assert bad_complete.json()["code"] == "PURCHASE_NOT_FOUND"

    # Préparation avec article inexistant
    bad_prep = client.post(
        "/api/v1/production/daily-preparations",
        headers=caissier_headers,
        json={
            "business_date": "2026-10-19",
            "article_id": "00000000-0000-0000-0000-000000000000",
            "prepared_quantity": 2,
            "yield_portions_per_unit": 4,
        },
    )
    assert bad_prep.status_code == 404
    assert bad_prep.json()["code"] == "ARTICLE_NOT_FOUND"

    # 9. Test de validation avec déduction du tiroir-caisse (deduct_from_cash_session=True)
    purchase_cash = client.post(
        "/api/v1/production/market-purchases",
        headers=caissier_headers,
        json={
            "business_date": "2026-10-20",
            "items": [{"article_id": chicken_art.id, "quantity": 2, "unit_price_xof": 3000}],
        },
    )
    assert purchase_cash.status_code == 201
    pc_id = purchase_cash.json()["id"]

    complete_cash_res = client.post(
        f"/api/v1/production/market-purchases/{pc_id}/complete?deduct_from_cash_session=true",
        headers=resp_headers,
    )
    assert complete_cash_res.status_code == 200
    assert complete_cash_res.json()["status"] == "COMPLETED"


def test_market_purchase_auto_creates_new_stock_article(client: TestClient, db_session: Session) -> None:
    """Vérifie qu'un nouvel article saisi par l'économe (qui n'existe pas en base)
    est créé automatiquement en stock lors de la soumission du bon de marché."""
    # Connexion Responsable
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    token = resp_login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    # Création du bon d'achat avec un article inexistant ("Gingembre Frais") et une protéine proto ("proto-Sosso")
    res = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-10-22",
            "notes": "Courses avec nouvel ingrédient",
            "items": [
                {
                    "custom_article_name": "Gingembre Frais",
                    "unit": "kg",
                    "category": "EPICERIE",
                    "quantity": 3.5,
                    "unit_price_xof": 1500,
                },
                {
                    "article_id": "proto-Sosso Poisson",
                    "quantity": 4,
                    "unit_price_xof": 4500,
                },
            ],
        },
    )
    assert res.status_code == 201, res.text
    data = res.json()
    assert data["status"] == "DRAFT"
    assert len(data["items"]) == 2
    purchase_id = data["id"]

    gingembre_item = next(i for i in data["items"] if "Gingembre" in i["article_name"])
    assert gingembre_item["quantity"] == 3.5
    assert gingembre_item["unit_price_xof"] == 1500
    assert gingembre_item["unit"] == "kg"

    # Vérification que l'article a été créé dans la table StockArticle
    gingembre_art = db_session.query(StockArticle).filter(StockArticle.name == "Gingembre Frais").first()
    assert gingembre_art is not None
    assert gingembre_art.category == "EPICERIE"
    assert gingembre_art.unit == "kg"
    assert gingembre_art.quantity == Decimal("0")

    # Validation du bon par le responsable
    complete_res = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/complete",
        headers=headers,
    )
    assert complete_res.status_code == 200
    assert complete_res.json()["status"] == "COMPLETED"

    # Le stock de Gingembre doit maintenant être entré à 3.5 kg
    db_session.refresh(gingembre_art)
    assert gingembre_art.quantity == Decimal("3.5")
    assert gingembre_art.avg_cost_xof == Decimal("1500")

