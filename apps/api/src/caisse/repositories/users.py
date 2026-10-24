from sqlalchemy.orm import Session

from caisse.models.user import User
from caisse.repositories.base import BaseRepository


class UserRepository(BaseRepository[User]):
    def __init__(self, db: Session):
        super().__init__(db, User)

    def get_by_name(self, full_name: str) -> User | None:
        return self.db.query(User).filter(User.full_name == full_name).first()

    def list_all(self, limit: int = 50) -> list[User]:
        return self.db.query(User).order_by(User.full_name.asc()).limit(limit).all()
