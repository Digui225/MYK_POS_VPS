from fastapi.testclient import TestClient

from caisse.core.security_rate_limit import rate_limiter


def test_e2e_security_suite(client: TestClient) -> None:
    """Scénario complet de vérification de la chaîne de sécurité de bout en bout."""
    rate_limiter.reset()

    # 1. Vérification des headers de durcissement HTTP sur une route système
    health_res = client.get("/health")
    assert health_res.status_code == 200
    assert health_res.headers.get("X-Content-Type-Options") == "nosniff"
    assert health_res.headers.get("X-Frame-Options") == "DENY"
    assert health_res.headers.get("Referrer-Policy") == "strict-origin-when-cross-origin"
    assert "geolocation=()" in health_res.headers.get("Permissions-Policy", "")

    # 2. Vérification du blocage d'un payload volumineux (anti-DoS mémoire)
    large_payload_res = client.post(
        "/api/v1/auth/login",
        content=b"{}",
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(10 * 1024 * 1024),  # 10 Mo
        },
    )
    assert large_payload_res.status_code == 413
    assert large_payload_res.json()["code"] == "PAYLOAD_TOO_LARGE"

    # 3. Vérification du rejet de Mass Assignment sur l'authentification
    mass_assign_res = client.post(
        "/api/v1/auth/login",
        json={
            "pin": "123456",
            "device_id": "pos-terminal-01",
            "is_admin": True,
            "role": "ADMIN",
        },
    )
    assert mass_assign_res.status_code == 422
    assert mass_assign_res.json()["code"] == "VALIDATION_ERROR"

    # 4. Connexion légitime
    login_res = client.post(
        "/api/v1/auth/login",
        json={"pin": "123456", "device_id": "pos-terminal-01"},
    )
    assert login_res.status_code == 200
    token = login_res.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}

    # 5. Ouvrir une session de caisse
    open_sess_res = client.post(
        "/api/v1/cash-sessions",
        headers={**headers, "Idempotency-Key": "e2e-sec-sess-001"},
        json={
            "cash_register_id": "reg-01",
            "opening_float_xof": 20000,
            "business_date": "2026-09-28",
        },
    )
    assert open_sess_res.status_code == 201

    # 6. Création et paiement complet d'une commande
    order_res = client.post(
        "/api/v1/orders",
        json={"guests_count": 2},
        headers=headers,
    )
    assert order_res.status_code == 201
    order_id = order_res.json()["id"]

    # Ajout d'un article hors menu
    item_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        json={"custom_name": "Plat Spécial", "unit_price_xof": 5000, "quantity": 1},
        headers=headers,
    )
    assert item_res.status_code == 200

    # Encaissement complet
    pay_res = client.post(
        f"/api/v1/orders/{order_id}/payments",
        json={
            "method": "CASH",
            "amount_xof": 5000,
            "tendered_xof": 5000,
        },
        headers={**headers, "Idempotency-Key": "550e8400-e29b-41d4-a716-446655440000"},
    )
    assert pay_res.status_code == 201
    assert pay_res.json()["order_status"] == "PAID"

    # 6. Règle d'immuabilité : tentative d'ajout d'article sur une commande soldée
    tamper_res = client.post(
        f"/api/v1/orders/{order_id}/items",
        json={"custom_name": "Fraude post-encaissement", "unit_price_xof": 2000, "quantity": 1},
        headers=headers,
    )
    assert tamper_res.status_code == 409
    assert tamper_res.json()["code"] == "ORDER_NOT_EDITABLE"

    # 7. Règle d'immuabilité : tentative d'annulation d'une commande soldée
    cancel_tamper_res = client.post(
        f"/api/v1/orders/{order_id}/cancel",
        json={"reason": "Annulation frauduleuse"},
        headers=headers,
    )
    assert cancel_tamper_res.status_code == 409
    assert cancel_tamper_res.json()["code"] == "ORDER_NOT_EDITABLE"
