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


def test_update_market_purchase_and_protein_analysis(client: TestClient, db_session: Session) -> None:
    """Vérifie l'ajustement d'un bon d'achat par le Patron (PUT) et l'analyse des écarts protéines."""
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    token = resp_login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    # Créer les 9 protéines en base si besoin pour le test
    from caisse.domain.enums import StockArticleCategory, StockOutMode
    beef_art = db_session.query(StockArticle).filter(StockArticle.name == "Bœuf").first()
    if not beef_art:
        beef_art = StockArticle(
            name="Bœuf",
            category=StockArticleCategory.PROTEINE,
            unit="kg",
            out_mode=StockOutMode.RECIPE,
            quantity=Decimal("3.0"),  # 3 kg déjà en réserve
            avg_cost_xof=Decimal("4000"),
            is_active=True,
        )
        db_session.add(beef_art)
        db_session.commit()
        db_session.refresh(beef_art)

    # 1. L'économe soumet un bon demandant 10 kg de bœuf (40 000 FCFA)
    create_res = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-10-29",
            "notes": "Demande initiale",
            "items": [
                {
                    "article_id": str(beef_art.id),
                    "quantity": 10.0,
                    "unit_price_xof": 4000,
                }
            ],
        },
    )
    assert create_res.status_code == 201
    purchase = create_res.json()
    purchase_id = purchase["id"]
    assert purchase["total_budget_xof"] == 40000

    # 2. Le Patron consulte l'analyse des 9 protéines
    analysis_res = client.get(
        f"/api/v1/production/market-purchases/{purchase_id}/protein-analysis",
        headers=headers,
    )
    assert analysis_res.status_code == 200
    analysis = analysis_res.json()
    assert analysis["purchase_id"] == purchase_id
    assert len(analysis["proteins"]) >= 1

    beef_analysis = next(p for p in analysis["proteins"] if p["article_name"] == "Bœuf")
    assert beef_analysis["requested_quantity"] == 10.0
    assert beef_analysis["unit_price_xof"] == 4000
    assert beef_analysis["current_stock_quantity"] >= 0
    # Recommandation = Demande (10) - Reste en cuisine/stock
    assert beef_analysis["recommended_quantity"] <= 10.0

    # 3. Le Patron ajuste la quantité à 7 kg (28 000 FCFA)
    update_res = client.put(
        f"/api/v1/production/market-purchases/{purchase_id}",
        headers=headers,
        json={
            "notes": "Ajusté par le Patron (3kg restant en cuisine)",
            "items": [
                {
                    "article_id": str(beef_art.id),
                    "quantity": 7.0,
                    "unit_price_xof": 4000,
                }
            ],
        },
    )
    assert update_res.status_code == 200
    updated_data = update_res.json()
    assert updated_data["total_budget_xof"] == 28000
    assert updated_data["notes"] == "Ajusté par le Patron (3kg restant en cuisine)"
    assert updated_data["items"][0]["quantity"] == 7.0

    # 4. Le Patron valide la réception
    complete_res = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/complete",
        headers=headers,
    )
    assert complete_res.status_code == 200
    assert complete_res.json()["status"] == "COMPLETED"

    # 5. Tentative de modifier un bon déjà COMPLETED -> Doit être rejetée (400)
    failed_update = client.put(
        f"/api/v1/production/market-purchases/{purchase_id}",
        headers=headers,
        json={
            "items": [
                {
                    "article_id": str(beef_art.id),
                    "quantity": 5.0,
                    "unit_price_xof": 4000,
                }
            ],
        },
    )
    assert failed_update.status_code == 400
    assert "PURCHASE_ALREADY_COMPLETED" in failed_update.text


def test_update_market_purchase_budget_limits_and_not_found(client: TestClient, db_session: Session) -> None:
    """Vérifie le respect du plafond budgétaire lors d'un PUT et les erreurs 404."""
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    assert resp_login.status_code == 200
    headers = {"Authorization": f"Bearer {resp_login.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}

    from caisse.domain.enums import StockArticleCategory, StockOutMode
    art = db_session.query(StockArticle).filter(StockArticle.name == "Poulet").first()
    if not art:
        art = StockArticle(
            name="Poulet",
            category=StockArticleCategory.PROTEINE,
            unit="pièce",
            out_mode=StockOutMode.RECIPE,
            quantity=Decimal("10.0"),
            avg_cost_xof=Decimal("3000"),
            is_active=True,
        )
        db_session.add(art)
        db_session.commit()
        db_session.refresh(art)

    # 1. Création d'un bon valide
    create_res = client.post(
        "/api/v1/production/market-purchases",
        headers=headers,
        json={
            "business_date": "2026-10-29",
            "notes": "Test plafond",
            "items": [{"article_id": str(art.id), "quantity": 10.0, "unit_price_xof": 3000}],
        },
    )
    assert create_res.status_code == 201
    pid = create_res.json()["id"]

    # 2. Mise à jour dépassant le plafond total de 300 000 FCFA (ex: 150 poulets * 3000 = 450 000 FCFA)
    over_res = client.put(
        f"/api/v1/production/market-purchases/{pid}",
        headers=headers,
        json={
            "items": [{"article_id": str(art.id), "quantity": 150.0, "unit_price_xof": 3000}],
        },
    )
    assert over_res.status_code == 422
    assert "MARKET_BUDGET_EXCEEDED" in over_res.text

    # 3. Modification d'un bon inexistant -> 404
    fake_res = client.put(
        "/api/v1/production/market-purchases/00000000-0000-0000-0000-000000000000",
        headers=headers,
        json={"items": [{"article_id": str(art.id), "quantity": 1.0, "unit_price_xof": 3000}]},
    )
    assert fake_res.status_code == 404



def test_auto_validate_preparations_on_session_close(client: TestClient, db_session: Session) -> None:
    """Test de l'Option A : la fermeture de la caisse valide automatiquement les sorties de cuisine
    suggérées pour les articles protéines d'après les ventes constatées, sans écraser les saisies manuelles."""
    # 1. Login responsable & caissier
    resp_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "test-device"},
    ).json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "test-device"}

    caissier_token = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "test-device"},
    ).json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "test-device"}

    # 2. Création d'une catégorie et produit
    cat_res = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Volailles Test", "kind": "FOOD"},
    )
    cat_id = cat_res.json()["id"]

    prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Pintade Braisée Test", "short_name": "PINTADE TEST", "price_xof": 5000},
    )
    prod_id = prod_res.json()["id"]

    # 3. Création article protéine en base avec fiche technique (1 pintade = 4 plats, portion = 0.25)
    from datetime import date
    from decimal import Decimal
    from caisse.domain.enums import StockArticleCategory, StockOutMode
    from caisse.models.production import DailyPreparation
    from caisse.models.stock import ProductComponent, StockArticle

    test_date = date.fromisoformat("2026-10-30")
    b_date_str = "2026-10-30"

    pintade_art = StockArticle(
        name="Pintade Fermière Test",
        category=StockArticleCategory.PROTEINE,
        unit="pièce",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal("20.0"),
        alert_threshold=Decimal("2.0"),
        avg_cost_xof=4000,
    )
    db_session.add(pintade_art)
    db_session.commit()
    db_session.refresh(pintade_art)

    comp = ProductComponent(
        product_id=prod_id,
        article_id=pintade_art.id,
        quantity=Decimal("0.25"),
    )
    db_session.add(comp)
    db_session.commit()

    # 4. Ouvrir une session de caisse
    open_sess = client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-autoval-01"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 20000,
            "business_date": b_date_str,
        },
    )
    assert open_sess.status_code == 201
    session_id = open_sess.json()["id"]

    # 5. Passer une commande de 8 plats de Pintade Braisée et l'encaisser
    order_res = client.post(
        "/api/v1/orders",
        headers=caissier_headers,
        json={"table_id": "tbl-01", "guests_count": 4},
    )
    assert order_res.status_code == 201
    order_id = order_res.json()["id"]

    add_item = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=caissier_headers,
        json={"product_id": prod_id, "quantity": 8},
    )
    assert add_item.status_code == 200

    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**caissier_headers, "Idempotency-Key": "pay-autoval-01"},
        json={"method": "CASH", "amount_xof": 40000, "tendered_xof": 40000},
    )
    assert pay_res.status_code == 201

    # 6. Vérifier avant clôture : pas encore de DailyPreparation pour pintade
    prep_before = (
        db_session.query(DailyPreparation)
        .filter(
            DailyPreparation.business_date == test_date,
            DailyPreparation.article_id == pintade_art.id,
        )
        .first()
    )
    assert prep_before is None

    # 7. Clôturer la session de caisse (Option A se déclenche ici)
    close_res = client.post(
        f"/api/v1/cash-sessions/{session_id}/close",
        headers={**caissier_headers, "Idempotency-Key": "close-autoval-01"},
        json={"counted_breakdown": {"10000": 6}},  # 20 000 ouverture + 40 000 vente = 60 000
    )
    assert close_res.status_code == 200, close_res.text

    # 8. Vérifier qu'une DailyPreparation a été créée automatiquement
    db_session.expire_all()
    prep_after = (
        db_session.query(DailyPreparation)
        .filter(
            DailyPreparation.business_date == test_date,
            DailyPreparation.article_id == pintade_art.id,
        )
        .first()
    )
    assert prep_after is not None
    # 8 plats vendus / 4 plats par pintade = 2.0 pintades sorties
    assert float(prep_after.prepared_quantity) == 2.0
    assert float(prep_after.yield_portions_per_unit) == 4.0
    assert prep_after.theoretical_dishes == 8
    assert "Auto-validé à la clôture de caisse" in (prep_after.notes or "")

    # 9. Vérifier dans la matrice hebdomadaire
    matrix_res = client.get(
        f"/api/v1/production/weekly-matrix?date_from={b_date_str}&date_to={b_date_str}",
        headers=resp_headers,
    )
    assert matrix_res.status_code == 200
    matrix_data = matrix_res.json()
    pintade_row = next((r for r in matrix_data["rows"] if r["article_id"] == pintade_art.id), None)
    assert pintade_row is not None
    day_data = pintade_row["days"][0]
    assert day_data["prepared_quantity"] == 2.0
    assert day_data["sold_dishes"] == 8
    assert day_data["theoretical_dishes"] == 8
    assert day_data["variance_dishes"] == 0
    assert "Auto-validé" in (day_data["notes"] or "")

    # 10. Protection de la saisie manuelle :
    # Création manuelle d'une sortie pour un autre article
    canard_art = StockArticle(
        name="Canard Test",
        category=StockArticleCategory.PROTEINE,
        unit="pièce",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal("15.0"),
        alert_threshold=Decimal("2.0"),
        avg_cost_xof=5000,
    )
    db_session.add(canard_art)
    db_session.commit()
    db_session.refresh(canard_art)

    canard_prod_res = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Canard Laqué Test", "short_name": "CANARD TEST", "price_xof": 6000},
    )
    canard_prod_id = canard_prod_res.json()["id"]

    db_session.add(
        ProductComponent(
            product_id=canard_prod_id,
            article_id=canard_art.id,
            quantity=Decimal("0.25"),  # 4 plats/canard
        )
    )
    manual_prep = DailyPreparation(
        business_date=test_date,
        article_id=str(canard_art.id),
        prepared_quantity=Decimal("5.0"),
        yield_portions_per_unit=Decimal("4.0"),
        theoretical_dishes=20,
        user_id=pintade_art.id,  # any valid user/id string
        notes="Sortie manuelle du matin par le chef",
    )
    # récupérer user_id du caissier
    from caisse.models.user import User
    c_user = db_session.query(User).filter(User.pin_hash.isnot(None)).first()
    assert c_user is not None
    manual_prep.user_id = c_user.id
    db_session.add(manual_prep)
    db_session.commit()

    # 11. Ouvrir une session 2 le même jour, vendre 4 pintades et 4 canards
    open_sess_2 = client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-autoval-02"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 15000,
            "business_date": b_date_str,
        },
    )
    assert open_sess_2.status_code == 201
    session_2_id = open_sess_2.json()["id"]

    order_2_res = client.post(
        "/api/v1/orders",
        headers=caissier_headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    )
    o2_id = order_2_res.json()["id"]

    client.post(f"/api/v1/orders/{o2_id}/items", headers=caissier_headers, json={"product_id": prod_id, "quantity": 4})
    client.post(f"/api/v1/orders/{o2_id}/items", headers=caissier_headers, json={"product_id": canard_prod_id, "quantity": 4})

    # total = 4 * 5000 + 4 * 6000 = 44 000
    pay_res_2 = client.post(
        f"/api/v1/orders/{o2_id}/payments",
        headers={**caissier_headers, "Idempotency-Key": "pay-autoval-02"},
        json={"method": "CASH", "amount_xof": 44000, "tendered_xof": 44000},
    )
    assert pay_res_2.status_code == 201

    # Clôture session 2 (15 000 fond + 44 000 = 59 000)
    close_2 = client.post(
        f"/api/v1/cash-sessions/{session_2_id}/close",
        headers={**caissier_headers, "Idempotency-Key": "close-autoval-02"},
        json={"counted_breakdown": {"10000": 5, "5000": 1, "2000": 2}},
    )
    assert close_2.status_code == 200

    db_session.expire_all()
    # A) Pintade : était auto-validée à 2.0 (8 plats). Avec +4 plats (total 12 plats) -> passe à 3.0 (12 / 4)
    pintade_prep_2 = db_session.query(DailyPreparation).filter(DailyPreparation.article_id == pintade_art.id, DailyPreparation.business_date == test_date).first()
    assert pintade_prep_2 is not None
    assert float(pintade_prep_2.prepared_quantity) == 3.0
    assert pintade_prep_2.theoretical_dishes == 12

    # B) Canard : saisie manuelle de 5.0 (20 plats) avec notes "Sortie manuelle...". NE DOIT PAS être écrasée par 4/4 = 1.0 !
    canard_prep_2 = db_session.query(DailyPreparation).filter(DailyPreparation.article_id == canard_art.id, DailyPreparation.business_date == test_date).first()
    assert canard_prep_2 is not None
    assert float(canard_prep_2.prepared_quantity) == 5.0
    assert canard_prep_2.theoretical_dishes == 20
    assert canard_prep_2.notes == "Sortie manuelle du matin par le chef"


def test_weekly_matrix_foufou_and_foutou_breakdown(client: TestClient, db_session: Session) -> None:
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    caissier_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    caissier_token = caissier_login.json()["access_token"]
    caissier_headers = {"Authorization": f"Bearer {caissier_token}", "X-Device-Id": "pos-terminal-01"}

    # Protéine
    machoiron_art = StockArticle(
        name="Mâchoiron Frais",
        category="PROTEINE",
        unit="kg",
        out_mode="RECIPE",
        quantity=Decimal("10"),
        avg_cost_xof=Decimal("3500"),
    )
    db_session.add(machoiron_art)
    db_session.flush()

    cat = Category(name="Poissons Plats", kind="FOOD", sort_order=10)
    db_session.add(cat)
    db_session.flush()

    p_normal = Product(category_id=cat.id, name="Mâchoiron Braisé", short_name="Mach Braise", price_xof=4000, vat_rate=Decimal("0.00"))
    p_foufou = Product(category_id=cat.id, name="Foufou Mâchoiron", short_name="Foufou Mach", price_xof=4500, vat_rate=Decimal("0.00"))
    p_foutou = Product(category_id=cat.id, name="Foutou banane Mâchoiron", short_name="Foutou Mach", price_xof=4500, vat_rate=Decimal("0.00"))
    db_session.add_all([p_normal, p_foufou, p_foutou])
    db_session.flush()

    # Recettes
    for p in [p_normal, p_foufou, p_foutou]:
        db_session.add(ProductComponent(product_id=p.id, article_id=machoiron_art.id, quantity=Decimal("0.333")))
    db_session.commit()

    b_date = "2026-10-30"

    # Ouvrir session de caisse
    open_sess = client.post(
        "/api/v1/cash-sessions",
        headers={**caissier_headers, "Idempotency-Key": "sess-foufou-foutou-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 10000, "business_date": b_date},
    )
    assert open_sess.status_code == 201

    # Commande : 1 normal, 1 foufou, 2 foutou (total 4 plats, 1 normal + 1 foufou + 2 foutou)
    ord_res = client.post("/api/v1/orders", headers=caissier_headers, json={"table_id": "tbl-01", "guests_count": 4})
    o_id = ord_res.json()["id"]

    client.post(f"/api/v1/orders/{o_id}/items", headers=caissier_headers, json={"product_id": p_normal.id, "quantity": 1})
    client.post(f"/api/v1/orders/{o_id}/items", headers=caissier_headers, json={"product_id": p_foufou.id, "quantity": 1})
    client.post(f"/api/v1/orders/{o_id}/items", headers=caissier_headers, json={"product_id": p_foutou.id, "quantity": 2})

    tot_xof = 1 * 4000 + 1 * 4500 + 2 * 4500  # 17500
    pay_res = client.post(
        f"/api/v1/orders/{o_id}/payments",
        headers={**caissier_headers, "Idempotency-Key": "pay-foufou-foutou-01"},
        json={"method": "CASH", "amount_xof": tot_xof, "tendered_xof": tot_xof},
    )
    assert pay_res.status_code == 201

    # Matrice hebdomadaire
    matrix_res = client.get(
        f"/api/v1/production/weekly-matrix?date_from={b_date}&date_to={b_date}",
        headers=resp_headers,
    )
    assert matrix_res.status_code == 200
    matrix_data = matrix_res.json()

    machoiron_row = next((r for r in matrix_data["rows"] if r["article_id"] == machoiron_art.id), None)
    assert machoiron_row is not None
    day_res = machoiron_row["days"][0]

    assert day_res["sold_dishes"] == 4
    assert day_res["normal_dishes_sold"] == 1
    assert day_res["foufou_dishes_sold"] == 1
    assert day_res["foutou_dishes_sold"] == 2





