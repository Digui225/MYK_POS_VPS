"""Module de compatibilité ascendante. Utilisez désormais `caisse.core.database`."""

from caisse.core.database import Base, SessionLocal, engine, get_db

__all__ = ["Base", "SessionLocal", "engine", "get_db"]
