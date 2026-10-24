from decimal import Decimal
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.domain.enums import FneStatus
from caisse.models.fne import FneDocument


def test_fne_issue_and_refund_idempotency(client: TestClient, db_session: Session) -> None:
    # 1. Login responsable
    resp_login = client.post(
        "/api/v1/auth/login",
        json={"pin": "654321", "device_id": "pos-terminal-01"},
    )
    resp_token = resp_login.json()["access_token"]
    resp_headers = {"Authorization": f"Bearer {resp_token}", "X-Device-Id": "pos-terminal-01"}

    # Config FNE minimale
    client.patch(
        "/api/v1/settings",
        headers=resp_headers,
        json={"fne_point_of_sale": "CAISSE1", "fne_establishment": "ABIDJAN-MYK"},
    )

    cat_id = client.post(
        "/api/v1/catalog/categories",
        headers=resp_headers,
        json={"name": "Poissons", "kind": "FOOD"},
    ).json()["id"]

    prod_id = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Capitaine Braisé", "price_xof": 10000},
    ).json()["id"]

    # 2. Login caissière et session
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "sess-fne-idem-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 20000, "business_date": "2026-09-28"},
    )

    # 3. Commande et encaissement
    order_id = client.post(
        "/api/v1/orders",
        headers=headers,
        json={"table_id": "tbl-01", "guests_count": 2},
    ).json()["id"]

    item_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        headers=headers,
        json={"product_id": prod_id, "quantity": 1},
    ).json()
    item_id = item_res["items"][0]["id"]

    client.post(
        f"/api/v1/orders/{order_id}/payments",
        headers={**headers, "Idempotency-Key": "pay-fne-idem-01"},
        json={"method": "CASH", "amount_xof": 10000, "tendered_xof": 10000},
    )

    # 4. Émission FNE idempotente
    idem_key = "fne-issue-unique-001"
    fne_headers = {**headers, "Idempotency-Key": idem_key}
    issue_payload = {"template": "B2C", "payment_method": "CASH"}

    issue_res_1 = client.post(
        f"/api/v1/orders/{order_id}/fne",
        headers=fne_headers,
        json=issue_payload,
    )
    assert issue_res_1.status_code == 201
    fne_data_1 = issue_res_1.json()
    doc_id = fne_data_1["document"]["id"]

    # 5. Rejeu émission FNE avec même clé et même corps -> 200 OK + header Idempotent-Replay
    issue_res_2 = client.post(
        f"/api/v1/orders/{order_id}/fne",
        headers=fne_headers,
        json=issue_payload,
    )
    assert issue_res_2.status_code == 200
    assert issue_res_2.headers.get("Idempotent-Replay") == "true"
    assert issue_res_2.json()["document"]["id"] == doc_id

    # Vérifier qu'un seul FneDocument a été créé en base
    fne_count = db_session.query(FneDocument).filter(FneDocument.order_id == order_id).count()
    assert fne_count == 1

    # 6. Émission FNE avec même clé mais corps différent -> 409 IDEMPOTENCY_CONFLICT
    conflict_res = client.post(
        f"/api/v1/orders/{order_id}/fne",
        headers=fne_headers,
        json={"template": "B2B", "payment_method": "MOBILE_MONEY"},
    )
    assert conflict_res.status_code == 409
    assert conflict_res.json()["code"] == "IDEMPOTENCY_CONFLICT"

    # 7. Avoir FNE (refund) idempotent
    # Préparer le document certifié avec items_map
    doc = db_session.get(FneDocument, doc_id)
    assert doc is not None
    doc.status = FneStatus.CERTIFIED
    doc.fne_invoice_id = "INV-2026-0001"
    doc.items_map = [{"order_item_id": item_id, "fne_item_id": "ITEM-1", "quantity": 1}]
    db_session.commit()

    refund_key = "fne-refund-unique-001"
    refund_headers = {**resp_headers, "Idempotency-Key": refund_key}
    refund_payload = {"items": [{"order_item_id": item_id, "quantity": 1}]}

    ref_res_1 = client.post(
        f"/api/v1/fne/documents/{doc_id}/refund",
        headers=refund_headers,
        json=refund_payload,
    )
    assert ref_res_1.status_code == 201
    refund_doc_id = ref_res_1.json()["document"]["id"]

    # Rejeu avoir
    ref_res_2 = client.post(
        f"/api/v1/fne/documents/{doc_id}/refund",
        headers=refund_headers,
        json=refund_payload,
    )
    assert ref_res_2.status_code == 200
    assert ref_res_2.headers.get("Idempotent-Replay") == "true"
    assert ref_res_2.json()["document"]["id"] == refund_doc_id

    # Conflit avoir
    ref_conflict = client.post(
        f"/api/v1/fne/documents/{doc_id}/refund",
        headers=refund_headers,
        json={"items": [{"order_item_id": item_id, "quantity": 2}]},
    )
    assert ref_conflict.status_code == 409
    assert ref_conflict.json()["code"] == "IDEMPOTENCY_CONFLICT"
