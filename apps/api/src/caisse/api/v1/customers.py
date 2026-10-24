from typing import Optional

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from caisse.database import get_db
from caisse.deps import get_current_user
from caisse.errors import CaisseException
from caisse.models.user import User
from caisse.schemas.customer import CustomerCreate, CustomerOut
from caisse.services import customer_service

router = APIRouter(prefix="/customers", tags=["Clients & FNE"])


@router.get("", response_model=list[CustomerOut], summary="Rechercher des clients")
def list_customers(
    q: Optional[str] = Query(None, description="Recherche libre"),
    search: Optional[str] = Query(None, description="Recherche libre (alias)"),
    ncc: Optional[str] = Query(None, description="Filtrer sur un NCC exact"),
    limit: int = Query(50, ge=1, le=100),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[CustomerOut]:
    query_str = search or q
    customers = customer_service.search_customers(db, query=query_str, ncc=ncc, limit=limit)
    return [CustomerOut.model_validate(c) for c in customers]


@router.post("", response_model=CustomerOut, status_code=status.HTTP_201_CREATED, summary="Créer un client d'entreprise")
def create_customer(
    payload: CustomerCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> CustomerOut:
    company_name = payload.company_name or payload.name or ""
    created = customer_service.create_customer(
        db,
        company_name=company_name,
        ncc=payload.ncc,
        tax_regime=payload.tax_regime,
        address=payload.address,
        phone=payload.phone,
        email=payload.email,
        actor_id=str(user.id),
    )
    return CustomerOut.model_validate(created)


@router.get("/{customer_id}", response_model=CustomerOut, summary="Détail d'un client")
def get_customer(
    customer_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> CustomerOut:
    cust = customer_service.get_by_id(db, customer_id)
    if not cust:
        raise CaisseException(
            code="CUSTOMER_NOT_FOUND",
            title="Client introuvable",
            detail=f"Aucun client trouvé avec l'ID {customer_id}.",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    return CustomerOut.model_validate(cust)
