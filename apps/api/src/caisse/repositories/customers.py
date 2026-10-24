from typing import Optional

from sqlalchemy import or_
from sqlalchemy.orm import Session

from caisse.models.customer import Customer


class CustomerRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, customer_id: str) -> Optional[Customer]:
        return self.db.query(Customer).filter(Customer.id == customer_id).first()

    def get_by_ncc(self, ncc: str) -> Optional[Customer]:
        return self.db.query(Customer).filter(Customer.ncc == ncc).first()

    def search(self, query: Optional[str] = None, limit: int = 50) -> list[Customer]:
        q = self.db.query(Customer).filter(Customer.is_active == True)
        if query:
            pattern = f"%{query}%"
            q = q.filter(
                or_(
                    Customer.name.ilike(pattern),
                    Customer.ncc.ilike(pattern),
                    Customer.phone.ilike(pattern),
                )
            )
        return q.order_by(Customer.name.asc()).limit(limit).all()

    def add(self, customer: Customer) -> Customer:
        self.db.add(customer)
        self.db.flush()
        return customer
