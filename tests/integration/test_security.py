from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from caisse.config import get_settings
from caisse.domain.enums import UserRole

pytestmark = pytest.mark.integration


def test_security_headers(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.headers["X-Content-Type-Options"] == "nosniff"
    assert resp.headers["X-Frame-Options"] == "DENY"
    assert resp.headers["Referrer-Policy"] == "strict-origin-when-cross-origin"


def test_payload_too_large(client: TestClient) -> None:
    resp = client.post(
        "/api/v1/auth/login", content=b"x" * (2 * 1024 * 1024 + 1), headers={"X-Request-Id": "big"}
    )
    assert resp.status_code == 413
    body = resp.json()
    assert (body["code"], body["request_id"]) == ("PAYLOAD_TOO_LARGE", "big")
    assert resp.headers["content-type"].startswith("application/problem+json")


def test_login_rate_limited_per_ip(client: TestClient, make_user) -> None:  # type: ignore[no-untyped-def]
    make_user("111111", UserRole.CAISSIER)
    for n in range(10):
        resp = client.post("/api/v1/auth/login", json={"pin": "999999", "device_id": f"poste-{n}"})
        assert resp.status_code in (401, 423), resp.text  # PIN faux, postes différents
    blocked = client.post("/api/v1/auth/login", json={"pin": "111111", "device_id": "neuf"})
    assert blocked.status_code == 429
    assert blocked.json()["code"] == "RATE_LIMIT_EXCEEDED"
    assert int(blocked.headers["Retry-After"]) >= 1
    assert blocked.json()["meta"]["limit"] == 10
    # les autres routes ne sont pas touchées
    assert client.get("/health").status_code == 200


@pytest.fixture
def app_with_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[pytest.MonkeyPatch]:
    """Recrée l'application avec d'autres variables d'environnement, puis rétablit."""
    yield monkeypatch
    monkeypatch.undo()
    get_settings.cache_clear()


def _fresh_client() -> TestClient:
    from caisse.main import create_app

    get_settings.cache_clear()
    return TestClient(create_app())


def test_docs_off_in_production(app_with_env: pytest.MonkeyPatch) -> None:
    app_with_env.setenv("APP_ENV", "production")
    with _fresh_client() as prod:
        assert prod.get("/docs").status_code == 404
        assert prod.get("/docs/static/swagger-ui.css").status_code == 404
        assert prod.get("/openapi.json").status_code == 404
    app_with_env.setenv("ENABLE_DOCS", "true")
    with _fresh_client() as prod:
        assert prod.get("/openapi.json").status_code == 200
        assert prod.get("/docs").status_code == 200


def test_swagger_served_without_cdn(client: TestClient) -> None:
    """Swagger UI vient de l'API : aucune page blanche sur un réseau qui bloque les CDN."""
    page = client.get("/docs")
    assert page.status_code == 200
    assert "https://" not in page.text  # rien de chargé hors de l'API
    assert '"/docs/static/swagger-ui-bundle.js"' in page.text
    js = client.get("/docs/static/swagger-ui-bundle.js")
    assert js.status_code == 200
    assert "javascript" in js.headers["content-type"]
    assert js.headers["x-content-type-options"] == "nosniff"
    css = client.get("/docs/static/swagger-ui.css")
    assert (css.status_code, css.headers["content-type"].split(";")[0]) == (200, "text/css")
    assert client.get("/redoc").status_code == 404


def test_allowed_hosts(app_with_env: pytest.MonkeyPatch) -> None:
    app_with_env.setenv("ALLOWED_HOSTS", "caisse.local, 192.168.1.10")
    with _fresh_client() as api:
        assert api.get("/health").status_code == 400  # Host: testserver
        assert api.get("/health", headers={"Host": "caisse.local"}).status_code == 200
