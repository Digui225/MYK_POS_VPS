from sqlalchemy.orm import Session
from fastapi import status

from caisse.errors import CaisseException
from caisse.models.catalog import Category, Product, ProductPriceHistory
from caisse.repositories.catalog import CatalogRepository
from caisse.schemas.catalog import (
    CategoryResponse,
    CategoryCreateRequest,
    CategoryUpdateRequest,
    ProductResponse,
    ProductCreateRequest,
    ProductPriceUpdateRequest,
)
from caisse.services.audit_service import AuditService


class CatalogService:
    def __init__(self, db: Session):
        self.db = db
        self.repo = CatalogRepository(db)
        self.audit = AuditService(db)

    def list_categories(self) -> list[CategoryResponse]:
        categories = self.repo.list_active_categories()
        return [
            CategoryResponse(
                id=c.id,
                name=c.name,
                kind=c.kind,  # type: ignore
                sort_order=c.sort_order,
                color=c.color,
                fiscal_group=c.fiscal_group,
                is_active=c.is_active,
            )
            for c in categories
        ]

    def create_category(
        self,
        payload: CategoryCreateRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> CategoryResponse:
        existing = self.repo.get_category_by_name(payload.name)
        if existing:
            raise CaisseException(
                code="CATEGORY_ALREADY_EXISTS",
                title="Catégorie déjà existante",
                detail=f"Une catégorie nommée '{payload.name}' existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )

        category = Category(
            name=payload.name,
            kind=payload.kind,
            sort_order=payload.sort_order,
            color=payload.color,
            fiscal_group=payload.fiscal_group,
            is_active=True,
        )
        created = self.repo.add_category(category)

        self.audit.log(
            action="CATEGORY_CREATED",
            entity="CATEGORY",
            entity_id=created.id,
            user_id=user_id,
            after={"name": payload.name, "kind": payload.kind},
            device_id=device_id,
        )
        self.db.commit()

        return CategoryResponse(
            id=created.id,
            name=created.name,
            kind=created.kind,  # type: ignore
            sort_order=created.sort_order,
            color=created.color,
            fiscal_group=created.fiscal_group,
            is_active=created.is_active,
        )

    def update_category(
        self,
        category_id: str,
        payload: CategoryUpdateRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> CategoryResponse:
        category = self.repo.get_category_by_id(category_id)
        if not category:
            raise CaisseException(
                code="CATEGORY_NOT_FOUND",
                title="Catégorie introuvable",
                detail=f"Aucune catégorie trouvée avec l'ID {category_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        before = {
            "name": category.name,
            "kind": category.kind,
            "sort_order": category.sort_order,
            "fiscal_group": category.fiscal_group,
            "is_active": category.is_active,
        }

        if payload.name and payload.name.strip() != category.name:
            existing = self.repo.get_category_by_name(payload.name.strip())
            if existing and existing.id != category.id:
                raise CaisseException(
                    code="CATEGORY_ALREADY_EXISTS",
                    title="Catégorie déjà existante",
                    detail=f"Une catégorie nommée '{payload.name}' existe déjà.",
                    status_code=status.HTTP_409_CONFLICT,
                )
            category.name = payload.name.strip()

        if payload.kind is not None:
            category.kind = payload.kind
        if payload.sort_order is not None:
            category.sort_order = payload.sort_order
        if payload.color is not None:
            category.color = payload.color
        if payload.fiscal_group is not None:
            category.fiscal_group = payload.fiscal_group
        if payload.is_active is not None:
            category.is_active = payload.is_active

        self.audit.log(
            action="CATEGORY_UPDATED",
            entity="CATEGORY",
            entity_id=category.id,
            user_id=user_id,
            before=before,
            after={
                "name": category.name,
                "kind": category.kind,
                "sort_order": category.sort_order,
                "fiscal_group": category.fiscal_group,
                "is_active": category.is_active,
            },
            device_id=device_id,
        )
        self.db.commit()

        return CategoryResponse(
            id=category.id,
            name=category.name,
            kind=category.kind,  # type: ignore
            sort_order=category.sort_order,
            color=category.color,
            fiscal_group=category.fiscal_group,
            is_active=category.is_active,
        )

    def list_products(self, category_id: str | None = None) -> list[ProductResponse]:
        from caisse.domain import stock_rules
        from caisse.repositories import stock as stock_repo

        products = self.repo.list_active_products(category_id)
        product_ids = [p.id for p in products]
        recipes = stock_repo.components_by_product(self.db, product_ids)

        result: list[ProductResponse] = []
        for p in products:
            recipe = recipes.get(p.id, [])
            has_recipe = len(recipe) > 0
            portions = (
                stock_rules.portions_available(
                    [(per_portion, article.quantity) for per_portion, article in recipe]
                )
                if has_recipe
                else None
            )
            result.append(
                ProductResponse(
                    id=p.id,
                    category_id=p.category_id,
                    name=p.name,
                    short_name=p.short_name,
                    price_xof=p.price_xof,
                    vat_rate=float(p.vat_rate),
                    track_stock=has_recipe or p.track_stock,
                    stock_quantity=float(portions) if portions is not None else None,
                    is_custom=p.is_custom,
                    is_active=p.is_active,
                    sort_order=p.sort_order,
                    color=p.color,
                    sku=p.sku,
                )
            )
        return result


    def create_product(
        self,
        payload: ProductCreateRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> ProductResponse:
        category = self.repo.get_category_by_id(payload.category_id)
        if not category:
            raise CaisseException(
                code="CATEGORY_NOT_FOUND",
                title="Catégorie introuvable",
                detail=f"Aucune catégorie trouvée avec l'ID {payload.category_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        product = Product(
            category_id=payload.category_id,
            name=payload.name,
            short_name=payload.short_name or payload.name[:20],
            price_xof=payload.price_xof,
            vat_rate=payload.vat_rate,
            track_stock=payload.track_stock,
            is_custom=False,
            is_active=True,
            color=payload.color,
            sku=payload.sku,
        )
        created = self.repo.add_product(product)

        self.audit.log(
            action="PRODUCT_CREATED",
            entity="PRODUCT",
            entity_id=created.id,
            user_id=user_id,
            after={"name": payload.name, "price_xof": payload.price_xof},
            device_id=device_id,
        )
        self.db.commit()

        return ProductResponse(
            id=created.id,
            category_id=created.category_id,
            name=created.name,
            short_name=created.short_name,
            price_xof=created.price_xof,
            vat_rate=float(created.vat_rate),
            track_stock=created.track_stock,
            is_custom=created.is_custom,
            is_active=created.is_active,
            sort_order=created.sort_order,
            color=created.color,
            sku=created.sku,
        )

    def update_product_price(
        self,
        product_id: str,
        payload: ProductPriceUpdateRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> ProductResponse:
        product = self.repo.get_product_by_id(product_id)
        if not product:
            raise CaisseException(
                code="PRODUCT_NOT_FOUND",
                title="Produit introuvable",
                detail=f"Aucun produit trouvé avec l'ID {product_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        old_price = product.price_xof
        product.price_xof = payload.new_price_xof

        # Historisation obligatoire de la modification tarifaire (ADR traçabilité)
        history = ProductPriceHistory(
            product_id=product.id,
            old_price_xof=old_price,
            new_price_xof=payload.new_price_xof,
            changed_by_user_id=user_id,
            reason=payload.reason,
        )
        self.repo.add_price_history(history)

        self.audit.log(
            action="PRODUCT_PRICE_CHANGED",
            entity="PRODUCT",
            entity_id=product.id,
            user_id=user_id,
            before={"price_xof": old_price},
            after={"price_xof": payload.new_price_xof},
            reason=payload.reason,
            device_id=device_id,
        )
        self.db.commit()

        return ProductResponse(
            id=product.id,
            category_id=product.category_id,
            name=product.name,
            short_name=product.short_name,
            price_xof=product.price_xof,
            vat_rate=float(product.vat_rate),
            track_stock=product.track_stock,
            is_custom=product.is_custom,
            is_active=product.is_active,
            sort_order=product.sort_order,
            color=product.color,
            sku=product.sku,
        )

    def get_product(self, product_id: str) -> ProductResponse:
        p = self.repo.get_product_by_id(product_id)
        if not p:
            raise CaisseException(
                code="PRODUCT_NOT_FOUND",
                title="Produit introuvable",
                detail=f"Aucun produit trouvé avec l'ID {product_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        from caisse.domain import stock_rules
        from caisse.repositories import stock as stock_repo

        recipe = stock_repo.components_by_product(self.db, [p.id]).get(p.id, [])
        has_recipe = len(recipe) > 0
        portions = (
            stock_rules.portions_available(
                [(per_portion, article.quantity) for per_portion, article in recipe]
            )
            if has_recipe
            else None
        )
        return ProductResponse(
            id=p.id,
            category_id=p.category_id,
            name=p.name,
            short_name=p.short_name,
            price_xof=p.price_xof,
            vat_rate=float(p.vat_rate),
            track_stock=has_recipe or p.track_stock,
            stock_quantity=float(portions) if portions is not None else None,
            is_custom=p.is_custom,
            is_active=p.is_active,
            sort_order=p.sort_order,
            color=p.color,
            sku=p.sku,
        )
