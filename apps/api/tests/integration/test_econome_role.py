import pytest
from decimal import Decimal
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.domain.enums import StockArticleCategory, StockOutMode
from caisse.models.stock import StockArticle
from caisse.models.user import User
from caisse.security import hash_pin


def test_econome_permissions_and_boundaries(client: TestClient, db_session: Session) -> None:
    """Vérifie les droits spécifiques de l'Économe :
    - Peut créer et consulter des bons d'achat marché
    - Peut enregistrer des préparations de cuisine
    - EST STRICTEMENT INTERDIT d'accéder aux fonctions caisse (sessions, commandes, paiements)
    - EST STRICTEMENT INTERDIT de valider les réceptions ou d'accéder à la matrice financière hebdo
    """
    # 1. Création de l'utilisateur Économe
    econome = User(
        full_name="Aïcha Économe",
        pin_hash=hash_pin("112233"),
        role="ECONOME",
        is_active=True,
    )
    # Création d'un responsable pour les tests de comparaison
    resp = User(
        full_name="Moussa Responsable",
        pin_hash=hash_pin("654321"),
        role="RESPONSABLE",
        is_active=True,
    )
    # Article de stock de test
    poulet = StockArticle(
        name="Poulet Entier",
        category=StockArticleCategory.PROTEINE,
        unit="pièce",
        out_mode=StockOutMode.RECIPE,
        quantity=Decimal("0"),
        avg_cost_xof=Decimal("3000"),
    )
    db_session.add_all([econome, resp, poulet])
    db_session.commit()

    # 2. Connexion par PIN de l'Économe
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "112233", "device_id": "tablet-cuisine-01"},
    )
    assert login_res.status_code == 200
    login_data = login_res.json()
    assert login_data["user"]["role"] == "ECONOME"
    assert login_data["user"]["full_name"] == "Aïcha Économe"
    econome_token = login_data["access_token"]
    econome_headers = {"Authorization": f"Bearer {econome_token}", "X-Device-Id": "tablet-cuisine-01"}

    # 3. L'Économe crée un bon d'achat marché -> AUTORISÉ (201)
    purchase_res = client.post(
        "/api/v1/production/market-purchases",
        headers=econome_headers,
        json={
            "business_date": "2026-10-22",
            "notes": "Courses du matin Économe",
            "items": [{"article_id": poulet.id, "quantity": 8, "unit_price_xof": 3000}],
        },
    )
    assert purchase_res.status_code == 201
    purchase_id = purchase_res.json()["id"]
    assert purchase_res.json()["total_budget_xof"] == 24000

    # 4. L'Économe consulte la liste et le détail -> AUTORISÉ (200)
    list_res = client.get("/api/v1/production/market-purchases", headers=econome_headers)
    assert list_res.status_code == 200
    assert len(list_res.json()) >= 1

    detail_res = client.get(f"/api/v1/production/market-purchases/{purchase_id}", headers=econome_headers)
    assert detail_res.status_code == 200

    # 5. L'Économe enregistre une sortie cuisine -> AUTORISÉ (200)
    prep_res = client.post(
        "/api/v1/production/daily-preparations",
        headers=econome_headers,
        json={
            "business_date": "2026-10-22",
            "article_id": poulet.id,
            "prepared_quantity": 4,
            "yield_portions_per_unit": 4,
        },
    )
    assert prep_res.status_code == 200

    # 6. SÉCURITÉ : L'Économe tente de valider la réception / décaisser -> INTERDIT (403)
    val_res = client.post(
        f"/api/v1/production/market-purchases/{purchase_id}/complete",
        headers=econome_headers,
    )
    assert val_res.status_code == 403
    assert val_res.json()["code"] == "INSUFFICIENT_PRIVILEGE"

    # 7. SÉCURITÉ : L'Économe tente de consulter la matrice hebdo du patron -> INTERDIT (403)
    matrix_res = client.get(
        "/api/v1/production/weekly-matrix?date_from=2026-10-19&date_to=2026-10-23",
        headers=econome_headers,
    )
    assert matrix_res.status_code == 403
    assert matrix_res.json()["code"] == "INSUFFICIENT_PRIVILEGE"

    # 8. SÉCURITÉ : L'Économe tente d'ouvrir une session de caisse -> INTERDIT (403)
    open_sess_res = client.post(
        "/api/v1/cash-sessions",
        headers={**econome_headers, "Idempotency-Key": "idem-open-01"},
        json={"cash_register_id": "caisse-01", "opening_float_xof": 50000},
    )
    assert open_sess_res.status_code == 403
    assert open_sess_res.json()["code"] == "INSUFFICIENT_PRIVILEGE"

    # 9. SÉCURITÉ : L'Économe tente de créer une commande POS -> INTERDIT (403)
    order_res = client.post(
        "/api/v1/orders",
        headers=econome_headers,
        json={"type": "DIRECT"},
    )
    assert order_res.status_code == 403
    assert order_res.json()["code"] == "INSUFFICIENT_PRIVILEGE"
