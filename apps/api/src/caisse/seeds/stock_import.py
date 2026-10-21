"""Import des articles de stock et des fiches techniques depuis les CSV de `seeds/data/`
(tirés des classeurs Excel du restaurant). Idempotent : un article existant n'est jamais
modifié, une fiche technique listée remplace celle du produit.

articles.csv          : categorie,nom,unite,prix_achat_xof,mode_sortie,stock_excel_13_10,…
fiches_techniques.csv : produit,article,quantite,…
"""

import csv
from collections import defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from caisse.domain.enums import StockArticleCategory, StockMovementType, StockOutMode
from caisse.models.catalog import Product
from caisse.models.stock import ProductComponent, StockArticle
from caisse.repositories import stock as stock_repo
from caisse.security import utcnow
from caisse.services import stock_service

DATA_DIR = Path(__file__).parent / "data"
ARTICLES_CSV = DATA_DIR / "articles.csv"
COMPONENTS_CSV = DATA_DIR / "fiches_techniques.csv"

OUT_MODES = {"FICHE": StockOutMode.RECIPE, "INVENTAIRE": StockOutMode.INVENTORY}
INITIAL_STOCK_REASON = "Reprise du stock Excel du 13/10/2026"


class StockImportError(ValueError):
    """Ligne de CSV invalide : le message donne le fichier et la ligne."""


@dataclass
class ArticlesImport:
    created: int = 0
    skipped: int = 0
    initial_counts: int = 0


def _rows(path: Path) -> list[tuple[int, dict[str, str]]]:
    with path.open(newline="", encoding="utf-8-sig") as fh:
        return [(n, row) for n, row in enumerate(csv.DictReader(fh), start=2)]


def _decimal(value: str, field: str, where: str) -> Decimal:
    try:
        return Decimal(value.strip().replace(",", "."))
    except InvalidOperation:
        raise StockImportError(f"{where} : {field} invalide ({value!r})") from None


def import_articles(
    db: Session, path: Path = ARTICLES_CSV, *, initial_stock: bool
) -> ArticlesImport:
    """Crée les articles absents (comparaison du nom sans la casse), au coût d'achat du CSV.
    `initial_stock` : inventaire de départ avec la colonne `stock_excel_13_10` pour les
    articles créés par cet import. Ne valide pas la transaction."""
    result = ArticlesImport()
    day = utcnow().date()
    for line_no, row in _rows(path):
        where = f"{path.name}, ligne {line_no}"
        try:
            name = row["nom"].strip()
            category = StockArticleCategory(row["categorie"].strip().upper())
            out_mode = OUT_MODES[row["mode_sortie"].strip().upper()]
            unit = row["unite"].strip()
        except (KeyError, ValueError) as exc:
            raise StockImportError(f"{where} : {exc}") from None
        if not name or not unit:
            raise StockImportError(f"{where} : nom et unité obligatoires")
        cost = _decimal(row.get("prix_achat_xof") or "0", "prix_achat_xof", where)
        if stock_repo.get_by_name(db, name) is not None:
            result.skipped += 1
            continue
        article = StockArticle(
            name=name,
            category=category,
            unit=unit,
            out_mode=out_mode,
            quantity=Decimal(0),
            avg_cost_xof=cost,
            is_active=True,
            note=(row.get("remarque") or "").strip() or None,
        )
        db.add(article)
        db.flush()
        result.created += 1
        start = (row.get("stock_excel_13_10") or "").strip()
        if initial_stock and start:
            stock_service.move(
                db,
                article,
                StockMovementType.OPENING,
                _decimal(start, "stock_excel_13_10", where),
                unit_cost=article.avg_cost_xof,
                business_date=day,
                user_id=None,
                reason=INITIAL_STOCK_REASON,
            )
            result.initial_counts += 1
    return result


def import_components(db: Session, path: Path = COMPONENTS_CSV) -> int:
    """Remplace la fiche technique de chaque produit cité (nom exact, hors articles libres).
    Retourne le nombre de produits mis à jour. Ne valide pas la transaction."""
    recipes: dict[Product, dict[StockArticle, Decimal]] = defaultdict(dict)
    for line_no, row in _rows(path):
        where = f"{path.name}, ligne {line_no}"
        product_name = (row.get("produit") or "").strip()
        product = db.scalar(
            select(Product).where(Product.name == product_name, Product.is_custom.is_(False))
        )
        if product is None:
            raise StockImportError(f"{where} : produit inconnu {product_name!r}")
        article = stock_repo.get_by_name(db, (row.get("article") or "").strip())
        if article is None:
            raise StockImportError(f"{where} : article inconnu {row.get('article')!r}")
        quantity = _decimal(row.get("quantite") or "", "quantite", where)
        if quantity <= 0:
            raise StockImportError(f"{where} : quantite doit être positive")
        if article in recipes[product]:
            raise StockImportError(f"{where} : {article.name} déjà dans la fiche de {product.name}")
        recipes[product][article] = quantity
    for product, lines in recipes.items():
        db.execute(delete(ProductComponent).where(ProductComponent.product_id == product.id))
        for article, quantity in lines.items():
            db.add(
                ProductComponent(product_id=product.id, article_id=article.id, quantity=quantity)
            )
    db.flush()
    return len(recipes)
