import argparse
import csv
import sys
from decimal import Decimal
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product
from caisse.models.settings import AppSetting


def cmd_set_vat_rate(db: Session, args: argparse.Namespace) -> None:
    try:
        rate = Decimal(args.rate).quantize(Decimal("0.01"))
    except Exception:
        sys.exit(f"Taux invalide : {args.rate}")
    if not Decimal(0) <= rate < Decimal(100):
        sys.exit("Le taux doit être compris entre 0 et 99,99.")
    setting = db.get(AppSetting, "vat.default_rate")
    if setting is None:
        db.add(AppSetting(key="vat.default_rate", value=str(rate)))
    else:
        setting.value = str(rate)
    changed = 0
    if args.all_products:
        for product in db.scalars(select(Product)):
            product.vat_rate = float(rate)
            changed += 1
    db.commit()
    print(f" Taux par défaut : {rate} %. Produits modifiés : {changed}.")


def cmd_import_catalog(db: Session, args: argparse.Namespace) -> None:
    menu_file = args.file or (Path(__file__).parents[2] / "seeds" / "data" / "menu.csv")
    with open(menu_file, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        count = 0
        for row in reader:
            cat_name = row["categorie"].strip()
            category = db.query(Category).filter(Category.name == cat_name).first()
            if not category:
                category = Category(
                    name=cat_name,
                    kind="DRINK" if "boisson" in cat_name.lower() or "eau" in cat_name.lower() else "FOOD",
                    fiscal_group=row.get("groupe_fiscal", "PLATS"),
                )
                db.add(category)
                db.flush()

            short_name = (row.get("nom_court") or row.get("nom_ticket") or row["nom"][:20]).strip()
            track_stock = row.get("suivi_stock", "false").lower() in ("true", "1", "oui")

            prod = db.query(Product).filter(Product.name == row["nom"].strip()).first()
            if not prod:
                prod = Product(
                    category_id=category.id,
                    name=row["nom"].strip(),
                    short_name=short_name,
                    price_xof=int(row["prix_xof"]),
                    track_stock=track_stock,
                )
                db.add(prod)
                count += 1
        db.commit()
        print(f" {count} produits importés avec succès depuis '{menu_file}'.")


def cmd_import_stock(db: Session, args: argparse.Namespace) -> None:
    from caisse.seeds.stock_import import (
        ARTICLES_CSV,
        COMPONENTS_CSV,
        import_articles,
        import_components,
    )

    art_path = Path(args.articles_csv) if args.articles_csv else ARTICLES_CSV
    comp_path = Path(args.fiches_csv) if args.fiches_csv else COMPONENTS_CSV
    res = import_articles(db, art_path, initial_stock=args.stock_initial)
    comps = import_components(db, comp_path)
    db.commit()
    print(
        f" Stock importé : {res.created} créés, {res.skipped} existants, "
        f"{res.initial_counts} comptages initiaux, {comps} fiches techniques."
    )
