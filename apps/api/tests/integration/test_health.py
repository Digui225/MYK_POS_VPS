from fastapi.testclient import TestClient
from caisse.main import app

client = TestClient(app)


def test_health_endpoint(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "app" in data


def test_health_ready_endpoint(client: TestClient) -> None:
    response = client.get("/health/ready")
    assert response.status_code == 200
    data = response.json()
    assert data["database"] is True


def test_openapi_schema_available() -> None:
    response = client.get("/openapi.json")
    assert response.status_code == 200
    schema = response.json()
    assert schema["info"]["title"] in ["OsisPos API", "Caisse MYK API"]
    assert "/api/v1/auth/login" in schema["paths"]
    assert "/api/v1/orders/{id}/payments" in schema["paths"]
    assert "/api/v1/cash-sessions" in schema["paths"]

