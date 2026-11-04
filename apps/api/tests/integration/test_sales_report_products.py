"""Détail des produits du rapport des ventes : chaque saisie libre (hors menu) garde son libellé
et n'est pas comptée comme « produit sans fiche technique »."""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product

DAY = "2026-11-10"


def _headers(client: TestClient, pin: str) -> dict[str, str]:
    token = client.post(
        "/api/v1/auth/login", json={"pin": pin, "device_id": "pos-terminal-01"}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}", "X-Device-Id": "pos-terminal-01"}


def test_hors_menu_regroupe_par_libelle_et_hors_produits_sans_fiche(
    client: TestClient, db_session: Session
) -> None:
    db_session.add(Category(id="cat-sup", name="Suppléments", kind="DISH"))
    db_session.add(
        Product(
            id="prod-alloco", category_id="cat-sup", name="Alloco", short_name="Alloco",
            price_xof=1000, is_active=True,
        )
    )
    db_session.commit()

    caissier = _headers(client, "123456")
    resp = _headers(client, "654321")
    client.post(
        "/api/v1/cash-sessions",
        headers={**caissier, "Idempotency-Key": f"sess-{uuid.uuid4()}"},
        json={"cash_register_id": "reg-01", "opening_float_xof": 0, "business_date": DAY},
    )
    oid = client.post(
        "/api/v1/orders", headers=caissier, json={"table_id": "tbl-01", "guests_count": 1}
    ).json()["id"]
    for line in (
        {"custom_name": "Foutou+ Faux brochet", "unit_price_xof": 3500, "quantity": 2},
        {"custom_name": "Tchep+Loss", "unit_price_xof": 3000, "quantity": 1},
        {"product_id": "prod-alloco", "quantity": 1},
    ):
        res = client.post(f"/api/v1/orders/{oid}/items", headers=caissier, json=line)
        assert res.status_code in (200, 201), res.text
    pay = client.post(
        f"/api/v1/orders/{oid}/payments",
        headers={**caissier, "Idempotency-Key": f"pay-{uuid.uuid4()}"},
        json={"method": "CASH", "amount_xof": 11000, "tendered_xof": 11000},
    )
    assert pay.status_code == 201, pay.text

    report = client.get(
        "/api/v1/reports/sales", headers=resp, params={"date_from": DAY, "date_to": DAY}
    ).json()
    products = {p["name"]: p for p in report["by_product"]}
    assert set(products) == {"Foutou+ Faux brochet", "Tchep+Loss", "Alloco"}
    assert products["Foutou+ Faux brochet"]["quantity"] == 2
    assert products["Foutou+ Faux brochet"]["revenue_xof"] == 7000
    assert products["Foutou+ Faux brochet"]["is_off_menu"] is True
    assert products["Foutou+ Faux brochet"]["product_id"] == "hors-menu:Foutou+ Faux brochet"
    assert products["Alloco"]["is_off_menu"] is False
    # Seul le produit du catalogue sans fiche compte (les hors menu ne peuvent pas en avoir)
    assert report["totals"]["uncosted_revenue_xof"] == 1000
