from typing import Optional

from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse.errors import CustomerNccExistsError
from caisse.models.customer import Customer


def get_by_ncc(db: Session, ncc: str) -> Customer | None:
    norm = ncc.replace(" ", "").upper()
    return db.execute(select(Customer).where(Customer.ncc == norm)).scalar_one_or_none()


def get_by_id(db: Session, customer_id: str) -> Customer | None:
    return db.get(Customer, customer_id)


def search_customers(db: Session, query: Optional[str] = None, ncc: Optional[str] = None, limit: int = 50) -> list[Customer]:
    stmt = select(Customer)
    if ncc:
        stmt = stmt.where(Customer.ncc == ncc.replace(" ", "").upper())
    elif query:
        pattern = f"%{query}%"
        stmt = stmt.where(
            or_(
                Customer.name.ilike(pattern),
                Customer.ncc.ilike(pattern),
                Customer.phone.ilike(pattern),
            )
        )
    stmt = stmt.limit(limit)
    return list(db.scalars(stmt).all())


def create_customer(
    db: Session,
    *,
    company_name: str,
    ncc: str | None = None,
    tax_regime: str | None = None,
    address: str | None = None,
    phone: str | None = None,
    email: str | None = None,
    actor_id: str | None = None,
) -> Customer:
    """Un NCC n'appartient qu'à un client : un doublon renvoie l'existant dans `meta`."""
    normalized_ncc = ncc.replace(" ", "").upper() if ncc else None
    if normalized_ncc is not None:
        existing = get_by_ncc(db, normalized_ncc)
        if existing is not None:
            raise CustomerNccExistsError(
                detail=f"Le NCC {normalized_ncc} est déjà attribué à {existing.name}",
                meta={"customer_id": str(existing.id), "ncc": normalized_ncc},
            )

    customer = Customer(
        name=company_name.strip(),
        ncc=normalized_ncc,
        tax_regime=tax_regime,
        address=address,
        phone=phone,
        email=email,
        is_active=True,
    )
    db.add(customer)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        existing = get_by_ncc(db, normalized_ncc) if normalized_ncc else None
        raise CustomerNccExistsError(
            detail=f"Le NCC {normalized_ncc} existe déjà",
            meta={"customer_id": str(existing.id) if existing else None, "ncc": normalized_ncc},
        ) from None

    db.commit()
    db.refresh(customer)
    return customer
