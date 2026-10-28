from fastapi.testclient import TestClient

from caisse.security import create_access_token


def test_payment_event_reaches_the_admin_dashboard(client: TestClient) -> None:
    """L'encaissement est une route synchrone (pool de threads) : son événement ORDER_PAID
    doit tout de même arriver aux écrans connectés."""
    resp_login = client.post("/api/v1/auth/login", json={"pin": "654321", "device_id": "pos-terminal-01"})
    resp_headers = {"Authorization": f"Bearer {resp_login.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}
    cat_id = client.post(
        "/api/v1/catalog/categories", headers=resp_headers, json={"name": "Grillades", "kind": "FOOD"}
    ).json()["id"]
    prod_id = client.post(
        "/api/v1/catalog/products",
        headers=resp_headers,
        json={"category_id": cat_id, "name": "Poulet Braisé Entier", "short_name": "POULET", "price_xof": 7000},
    ).json()["id"]

    login = client.post("/api/v1/auth/login", json={"pin": "123456", "device_id": "pos-terminal-01"})
    headers = {"Authorization": f"Bearer {login.json()['access_token']}", "X-Device-Id": "pos-terminal-01"}
    client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "ws-sess-01"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 25000, "business_date": "2026-09-28"},
    )
    order_id = client.post("/api/v1/orders", headers=headers, json={"table_id": "tbl-01", "guests_count": 2}).json()["id"]
    client.post(f"/api/v1/orders/{order_id}/items", headers=headers, json={"product_id": prod_id, "quantity": 1})

    admin_token = create_access_token("usr-admin-01", "ADMIN")
    with client.websocket_connect(f"/api/v1/ws?token={admin_token}") as websocket:
        pay = client.post(
            f"/api/v1/orders/{order_id}/payments",
            headers={**headers, "Idempotency-Key": "ws-pay-01"},
            json={"method": "CASH", "amount_xof": 7000, "tendered_xof": 10000},
        )
        assert pay.status_code == 201

        event = websocket.receive_json()
        assert event["type"] == "ORDER_PAID"
        assert event["data"]["order_id"] == order_id
        assert event["data"]["paid_xof"] == 7000
