import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.database import Base
from caisse.models.settings import AppSetting
from caisse.repositories import settings as settings_repo
from caisse.services.fne_service import _issuer


def test_settings_repo_get_set_value() -> None:
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(bind=engine)

    with Session(engine) as db:
        # Default value when not found
        assert settings_repo.get_value(db, "fne.point_of_sale", "default_pos") == "default_pos"

        # Set value
        settings_repo.set_value(db, "fne.point_of_sale", "point de vente 1", user_id="admin-01")
        db.commit()

        # Retrieve value
        val = settings_repo.get_value(db, "fne.point_of_sale")
        assert val == "point de vente 1"

        # Update value
        settings_repo.set_value(db, "fne.point_of_sale", "point de vente 2", user_id="admin-02")
        db.commit()
        assert settings_repo.get_value(db, "fne.point_of_sale") == "point de vente 2"


def test_fne_service_issuer_reads_from_settings() -> None:
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(bind=engine)

    with Session(engine) as db:
        settings_repo.set_value(db, "fne.point_of_sale", "point de vente 1")
        settings_repo.set_value(db, "fne.establishment", "RESTAURANT CHEZ SYLLA PLUS")
        db.commit()

        issuer = _issuer(db)
        assert issuer.point_of_sale == "point de vente 1"
        assert issuer.establishment == "RESTAURANT CHEZ SYLLA PLUS"


def test_fne_service_issuer_corrects_caisse_1_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(bind=engine)

    cfg = get_settings()
    monkeypatch.setattr(cfg, "FNE_API_BASE_URL", "https://services.fne.dgi.gouv.ci/api/v1")

    with Session(engine) as db:
        settings_repo.set_value(db, "fne.point_of_sale", "CAISSE-1")
        settings_repo.set_value(db, "fne.establishment", "RESTAURANT CHEZ SYLLA PLUS")
        db.commit()

        issuer = _issuer(db)
        # Should be corrected to "point de vente 1"
        assert issuer.point_of_sale == "point de vente 1"
