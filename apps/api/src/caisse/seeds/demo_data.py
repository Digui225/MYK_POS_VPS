from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product
from caisse.models.table import RestaurantTable


def seed_catalog_and_tables(db: Session) -> None:
    # 1. Catégories
    if not db.query(Category).first():
        cat_poissons = Category(
            id="cat-01",
            name="Poissons braisés",
            kind="FOOD",
            sort_order=1,
            color="#f59e0b",
            fiscal_group="PLATS",
            is_active=True,
        )
        cat_viandes = Category(
            id="cat-02",
            name="Viandes & Poulets",
            kind="FOOD",
            sort_order=2,
            color="#ef4444",
            fiscal_group="PLATS",
            is_active=True,
        )
        cat_bieres = Category(
            id="cat-03",
            name="Bières & Boissons",
            kind="DRINK",
            sort_order=3,
            color="#3b82f6",
            fiscal_group="BOISSONS",
            is_active=True,
        )
        cat_eaux = Category(
            id="cat-04",
            name="Eaux & Jus",
            kind="DRINK",
            sort_order=4,
            color="#10b981",
            fiscal_group="BOISSONS",
            is_active=True,
        )
        db.add_all([cat_poissons, cat_viandes, cat_bieres, cat_eaux])
        db.flush()

        # 2. Produits
        prod_capitaine = Product(
            id="prod-01",
            category_id="cat-01",
            name="Capitaine braisé moyen",
            short_name="CAPITAINE MOY",
            price_xof=6000,
            vat_rate=0.0,
            track_stock=False,
            is_active=True,
            sort_order=1,
        )
        prod_carpe = Product(
            id="prod-02",
            category_id="cat-01",
            name="Carpe braisée grande",
            short_name="CARPE GDE",
            price_xof=5500,
            vat_rate=0.0,
            track_stock=False,
            is_active=True,
            sort_order=2,
        )
        prod_poulet = Product(
            id="prod-03",
            category_id="cat-02",
            name="Choukouya de Poulet",
            short_name="CHOUKOUYA PLT",
            price_xof=4500,
            vat_rate=0.0,
            track_stock=False,
            is_active=True,
            sort_order=1,
        )
        prod_bock = Product(
            id="prod-04",
            category_id="cat-03",
            name="Bière Bock 65cl",
            short_name="BOCK 65CL",
            price_xof=1000,
            vat_rate=0.0,
            track_stock=True,
            is_active=True,
            sort_order=1,
        )
        prod_eau = Product(
            id="prod-05",
            category_id="cat-04",
            name="Eau minérale Awa 1.5L",
            short_name="EAU AWA 1.5L",
            price_xof=700,
            vat_rate=0.0,
            track_stock=True,
            is_active=True,
            sort_order=1,
        )
        db.add_all([prod_capitaine, prod_carpe, prod_poulet, prod_bock, prod_eau])

    # 3. Tables
    if not db.query(RestaurantTable).first():
        tables = [
            RestaurantTable(id=f"tbl-0{i}", label=f"Table {i}", zone="Salle", seats=4, sort_order=i, is_active=True)
            for i in range(1, 9)
        ]
        db.add_all(tables)

    db.commit()
