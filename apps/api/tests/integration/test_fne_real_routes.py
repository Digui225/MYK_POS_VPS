import uuid
from typing import Any
from fastapi.testclient import TestClient
import pytest

from caisse.deps import get_fne_provider
from caisse.domain.ports import FneRejectedError, FneUnavailableError, FneUncertainError
from caisse.infrastructure.fne import MockFneProvider
from caisse.main import app


@pytest.fixture
def mock_fne() -> MockFneProvider:
    return MockFneProvider(ncc="1304777N")


def test_fne_real_api_routes_lifecycle(client: TestClient, mock_fne: MockFneProvider) -> None:
    app.dependency_overrides[get_fne_provider] = lambda: mock_fne

    # 1. Login responsable
    login_resp = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-01"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-01"}

    # 2. Créer catégorie et produit en tant que responsable
    cat_resp = client.post(
        "/api/v1/catalog/categories",
        headers=headers,
        json={"name": "Plats", "kind": "FOOD", "sort_order": 1},
    )
    cat_id = cat_resp.json()["id"]
    prod_resp = client.post(
        "/api/v1/catalog/products",
        headers=headers,
        json={"category_id": cat_id, "name": "Thiéboudienne", "short_name": "THIEB", "price_xof": 4000, "vat_rate": 0.0},
    )
    prod = prod_resp.json()
    prod_id = prod["id"]
    price = prod["price_xof"]

    # 3. Créer client B2B avec NCC
    cust_resp = client.post(
        "/api/v1/customers",
        headers=headers,
        json={"name": "ORANGE CI", "ncc": "9506466A", "phone": "0709080765", "email": "contact@orange.ci"},
    )
    assert cust_resp.status_code == 201
    customer_id = cust_resp.json()["id"]

    # 4. Login caissier pour session et commande
    cais_login = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-01"})
    assert cais_login.status_code == 200
    cais_token = cais_login.json()["access_token"]
    cais_headers = {"Authorization": f"Bearer {cais_token}", "X-Device-Id": "pos-01"}

    # 5. Ouvrir session de caisse
    client.post(
        "/api/v1/cash-sessions",
        headers={**cais_headers, "Idempotency-Key": "sess-fne-test-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": "2026-10-02"},
    )

    # 6. Créer commande
    order = client.post("/api/v1/orders", headers=cais_headers, json={"table_id": "tbl-01", "guests_count": 1}).json()
    order_id = order["id"]
    item = client.post(f"/api/v1/orders/{order_id}/items", headers=cais_headers, json={"product_id": prod_id, "quantity": 2}).json()
    order_item_id = item["items"][0]["id"]

    # 7. Payer commande
    client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**cais_headers, "Idempotency-Key": "pay-fne-test-01"},
        json={"method": "CASH", "amount_xof": price * 2, "tendered_xof": price * 2},
    )

    # 4. Émettre FNE B2B via POST /api/v1/orders/{id}/fne
    issue_resp = client.post(
        f"/api/v1/orders/{order_id}/fne",
        headers=headers,
        json={"template": "B2B", "customer_id": customer_id},
    )
    assert issue_resp.status_code == 201
    res_data = issue_resp.json()
    doc = res_data["document"]
    assert doc["status"] == "CERTIFIED"
    assert doc["external_number"].startswith("1304777N")
    assert doc["qr_payload"].startswith("mock://fne/verification/")
    doc_id = doc["id"]

    # 5. Consulter la FNE de la commande via GET /api/v1/orders/{id}/fne
    get_order_fne = client.get(f"/api/v1/orders/{order_id}/fne", headers=headers)
    assert get_order_fne.status_code == 200
    assert get_order_fne.json()["id"] == doc_id

    # 6. Duplicata
    dup_resp = client.get(f"/api/v1/fne/documents/{doc_id}/duplicate", headers=headers)
    assert dup_resp.status_code == 200
    assert dup_resp.json()["external_number"] == doc["external_number"]

    # 7. Compteurs en attente
    count_resp = client.get("/api/v1/fne/pending-count", headers=headers)
    assert count_resp.status_code == 200
    assert "pending" in count_resp.json()

    # 7b. Compteurs avec filtre business_date
    count_filtered = client.get("/api/v1/fne/pending-count?business_date=2026-10-30", headers=headers)
    assert count_filtered.status_code == 200
    assert "pending" in count_filtered.json()

    # 8. Récapitulatif journalier
    daily_resp = client.get("/api/v1/fne/daily-summary", headers=headers)
    assert daily_resp.status_code == 200
    assert daily_resp.json()["certified_orders"] >= 1

    # 9. Émettre un avoir (Refund)
    refund_resp = client.post(
        f"/api/v1/fne/documents/{doc_id}/refund",
        headers=headers,
        json={"items": [{"order_item_id": order_item_id, "quantity": 1}]},
    )
    assert refund_resp.status_code == 201
    refund_doc = refund_resp.json()["document"]
    assert refund_doc["type"] == "REFUND"
    assert refund_doc["status"] == "CERTIFIED"
    assert refund_doc["parent_document_id"] == doc_id
