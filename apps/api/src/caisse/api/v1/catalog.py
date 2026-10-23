from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import CurrentUser, require_role, require_device_id
from caisse.models.user import User
from caisse.schemas.catalog import (
    CategoryResponse,
    CategoryCreateRequest,
    ProductResponse,
    ProductCreateRequest,
    ProductPriceUpdateRequest,
)
from caisse.services.catalog_service import CatalogService

router = APIRouter(tags=["Catalogue"])


@router.get("/categories", response_model=list[CategoryResponse], summary="Lister les catégories actives")
@router.get("/catalog/categories", response_model=list[CategoryResponse], summary="Lister les catégories actives (alias)")
async def list_categories(
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    db: Session = Depends(get_db),
) -> list[CategoryResponse]:
    service = CatalogService(db)
    return service.list_categories()


@router.post(
    "/categories",
    response_model=CategoryResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Créer une catégorie (Responsable/Admin)",
)
@router.post(
    "/catalog/categories",
    response_model=CategoryResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Créer une catégorie (alias)",
)
async def create_category(
    payload: CategoryCreateRequest,
    current_user: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> CategoryResponse:
    service = CatalogService(db)
    return service.create_category(payload, user_id=current_user.id, device_id=device_id)


@router.get("/products", response_model=list[ProductResponse], summary="Lister les produits actifs du menu")
@router.get("/catalog/products", response_model=list[ProductResponse], summary="Lister les produits actifs du menu (alias)")
async def list_products(
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    category_id: str | None = None,
    db: Session = Depends(get_db),
) -> list[ProductResponse]:
    service = CatalogService(db)
    return service.list_products(category_id=category_id)


@router.get("/products/{id}", response_model=ProductResponse, summary="Détail d'un produit")
@router.get("/catalog/products/{id}", response_model=ProductResponse, summary="Détail d'un produit (alias)")
async def get_product(
    id: str,
    current_user: User = Depends(require_role("CAISSIER", "RESPONSABLE", "ADMIN")),
    db: Session = Depends(get_db),
) -> ProductResponse:
    service = CatalogService(db)
    return service.get_product(id)


@router.post(
    "/products",
    response_model=ProductResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un produit (Responsable/Admin)",
)
@router.post(
    "/catalog/products",
    response_model=ProductResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Créer un produit (alias)",
)
async def create_product(
    payload: ProductCreateRequest,
    current_user: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> ProductResponse:
    service = CatalogService(db)
    return service.create_product(payload, user_id=current_user.id, device_id=device_id)


@router.patch(
    "/products/{id}/price",
    response_model=ProductResponse,
    summary="Modifier le prix d'un produit (tracé, Responsable/Admin)",
)
@router.patch(
    "/catalog/products/{id}/price",
    response_model=ProductResponse,
    summary="Modifier le prix d'un produit (alias)",
)
async def update_product_price(
    id: str,
    payload: ProductPriceUpdateRequest,
    current_user: User = Depends(require_role("RESPONSABLE", "ADMIN")),
    device_id: str = Depends(require_device_id),
    db: Session = Depends(get_db),
) -> ProductResponse:
    service = CatalogService(db)
    return service.update_product_price(id, payload, user_id=current_user.id, device_id=device_id)
