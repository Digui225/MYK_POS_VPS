"""Script de purge des données mockées et d'importation officielle du menu Restaurant Sylla Plus.

Usage:
    .venv/bin/python -m caisse.seeds.import_sylla_menu
"""

from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session

from caisse.database import SessionLocal
from caisse.models.catalog import Category, Product
from caisse.models.stock import StockItem


@dataclass
class CategoryData:
    name: str
    items: list[tuple[str, int, str | None]] = field(default_factory=list)


CATEGORY_CONFIG = {
    "Spécial Kabato": {"kind": "FOOD", "color": "ambre", "sort_order": 1},
    "Spécial Sauce": {"kind": "FOOD", "color": "vert", "sort_order": 2},
    "Spécial Oriental": {"kind": "FOOD", "color": "orange", "sort_order": 3},
    "Spécial Salade": {"kind": "FOOD", "color": "cyan", "sort_order": 4},
    "Spécial Sénégal": {"kind": "FOOD", "color": "rouge", "sort_order": 5},
    "Spécial Ivoirienne": {"kind": "FOOD", "color": "brun", "sort_order": 6},
    "Spécial Desserts": {"kind": "FOOD", "color": "rose", "sort_order": 7},
    "Spécial Jus": {"kind": "DRINK", "color": "bleu", "sort_order": 8},
}


def make_short_name(name: str) -> str:
    """Crée un libellé ticket de caisse concis (max 20 caractères)."""
    if len(name) <= 20:
        return name
    abbrevs = {
        "Poisson braisé": "Pois.Braisé",
        "Salade Panachée": "Salade Pan.",
        "Igname bouillie": "Ign.Bouillie",
        "Igname frite": "Ign.Frite",
        "Sauce Feuille": "Sce Feuille",
        "Sauce Légume": "Sce Légume",
        "Sauce Dah": "Sce Dah",
        "Kabato Kope": "Kab.Kope",
        "Kabato Lafri": "Kab.Lafri",
        "Kabato Dah": "Kab.Dah",
        "Petit pois": "P.Pois",
    }
    short = name
    for k, v in abbrevs.items():
        if k in short:
            short = short.replace(k, v)
    if len(short) > 20:
        short = short.replace(" + ", "+")
    if len(short) > 20:
        short = short[:20].strip()
    return short


def purge_mock_data(db: Session) -> dict[str, int]:
    """Purge toutes les données de simulation et de test (commandes, sessions, tables, catalogue).
    Conserve strictement les utilisateurs, les réglages établissement et les caisses physiques.
    """
    tables_to_purge = [
        "order_items",
        "payments",
        "fne_documents",
        "outbox_events",
        "print_jobs",
        "stock_movements",
        "orders",
        "cash_movements",
        "cash_sessions",
        "stock_items",
        "product_price_history",
        "products",
        "categories",
        "restaurant_tables",
        "idempotency_records",
    ]

    allowed_tables = frozenset(tables_to_purge)
    deleted_counts = {}
    for tbl in tables_to_purge:
        if tbl not in allowed_tables:
            raise ValueError(f"Table non autorisée pour la purge : {tbl}")
        result = db.execute(text(f'DELETE FROM "{tbl}"'))
        deleted_counts[tbl] = result.rowcount if isinstance(result, CursorResult) and result.rowcount is not None else 0

    db.commit()
    return deleted_counts


def parse_and_import_menu(db: Session, menu_path: Path) -> tuple[int, int]:
    """Lit le fichier menu-sylla-plus.md et insère les catégories et les plats."""
    if not menu_path.exists():
        raise FileNotFoundError(f"Fichier menu introuvable : {menu_path}")

    content = menu_path.read_text(encoding="utf-8")

    categories_data: list[CategoryData] = []
    current_cat: CategoryData | None = None
    current_subcat: str | None = None

    for line in content.splitlines():
        line = line.strip()
        if line.startswith("## "):
            cat_name = line[3:].strip()
            current_cat = CategoryData(name=cat_name)
            categories_data.append(current_cat)
            current_subcat = None
        elif line.startswith("### "):
            current_subcat = line[4:].strip()
        elif line.startswith("|") and not line.startswith("|---") and not line.startswith("| Plat") and not line.startswith("| Dessert") and not line.startswith("| Jus"):
            parts = [p.strip() for p in line.split("|") if p.strip()]
            if len(parts) >= 2:
                item_name = parts[0]
                try:
                    price = int(parts[1].replace(" ", ""))
                    if current_cat:
                        current_cat.items.append((item_name, price, current_subcat))
                except ValueError:
                    pass

    total_categories = 0
    total_products = 0
    sku_counter = 1

    for cat_data in categories_data:
        cat_name = cat_data.name
        cfg = CATEGORY_CONFIG.get(cat_name, {"kind": "FOOD", "color": "ardoise", "sort_order": 99})

        category = Category(
            name=cat_name,
            kind=cfg["kind"],
            color=cfg["color"],
            sort_order=cfg["sort_order"],
            is_active=True,
            fiscal_group=cfg["kind"],
        )
        db.add(category)
        db.flush()
        total_categories += 1

        p_sort = 1
        for item_name, price, _ in cat_data.items:
            short_name = make_short_name(item_name)
            sku = f"SYL-{sku_counter:03d}"
            sku_counter += 1

            is_drink = cfg["kind"] == "DRINK"
            product = Product(
                category_id=category.id,
                name=item_name,
                short_name=short_name,
                price_xof=price,
                vat_rate=0.00,
                track_stock=is_drink,
                is_custom=False,
                is_active=True,
                sort_order=p_sort,
                color=cfg["color"],
                sku=sku,
            )
            db.add(product)
            db.flush()

            # Créer l'entrée stock UNIQUEMENT pour les boissons (produits unitaires en bouteilles)
            if is_drink:
                stock = StockItem(
                    product_id=product.id,
                    quantity=50.0,
                    alert_threshold=10.0,
                    unit="bouteille",
                )
                db.add(stock)

            p_sort += 1
            total_products += 1

    db.commit()
    return total_categories, total_products


def main() -> None:
    db = SessionLocal()
    try:
        print("🚀 Démarrage de la purge des données de simulation...")
        deleted = purge_mock_data(db)
        for tbl, cnt in deleted.items():
            if cnt > 0:
                print(f"   ✓ {tbl} : {cnt} enregistrements supprimés")
        print("✅ Purge terminée avec succès.")

        menu_file = Path("/home/osisgroup/Documents/Caisse_MYK_frontend/menu-sylla-plus.md")
        print(f"\n📖 Importation du menu officiel depuis {menu_file.name}...")
        nb_cats, nb_prods = parse_and_import_menu(db, menu_file)
        print(f"✅ Menu Sylla Plus importé : {nb_cats} catégories et {nb_prods} plats/boissons créés !")
        print("💡 Les tables ont été remises à 0 : l'administrateur peut maintenant configurer la salle en situation réelle.")
    finally:
        db.close()


if __name__ == "__main__":
    main()
