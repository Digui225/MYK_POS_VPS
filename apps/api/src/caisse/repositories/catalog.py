from sqlalchemy.orm import Session

from caisse.models.catalog import Category, Product, ProductPriceHistory
from caisse.repositories.base import BaseRepository


class CatalogRepository(BaseRepository[Category]):
    def __init__(self, db: Session):
        super().__init__(db, Category)

    def list_active_categories(self) -> list[Category]:
        return (
            self.db.query(Category)
            .filter(Category.is_active.is_(True))
            .order_by(Category.sort_order.asc(), Category.name.asc())
            .all()
        )

    def get_category_by_id(self, category_id: str) -> Category | None:
        return self.db.query(Category).filter(Category.id == category_id).first()

    def get_category_by_name(self, name: str) -> Category | None:
        return self.db.query(Category).filter(Category.name == name).first()

    def add_category(self, category: Category) -> Category:
        self.db.add(category)
        self.db.flush()
        return category

    def list_active_products(self, category_id: str | None = None) -> list[Product]:
        query = self.db.query(Product).filter(
            Product.is_active.is_(True),
            Product.is_custom.is_(False),
        )
        if category_id:
            query = query.filter(Product.category_id == category_id)
        return query.order_by(Product.sort_order.asc(), Product.name.asc()).all()

    def get_product_by_id(self, product_id: str) -> Product | None:
        return self.db.query(Product).filter(Product.id == product_id).first()

    def add_product(self, product: Product) -> Product:
        self.db.add(product)
        self.db.flush()
        return product

    def add_price_history(self, history: ProductPriceHistory) -> ProductPriceHistory:
        self.db.add(history)
        self.db.flush()
        return history

    def get_price_history(self, product_id: str) -> list[ProductPriceHistory]:
        return (
            self.db.query(ProductPriceHistory)
            .filter(ProductPriceHistory.product_id == product_id)
            .order_by(ProductPriceHistory.changed_at.desc())
            .all()
        )
