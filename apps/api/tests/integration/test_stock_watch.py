"""Stock à surveiller du tableau de bord : protéines et boissons au regard du prochain marché,
au rythme des ventes des derniers jours d'ouverture."""

from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy.orm import Session

from caisse.domain.enums import CashSessionStatus
from caisse.models.cash_session import CashSession
from caisse.models.catalog import Category, Product
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.services.reporting_service import stock_watch

MERCREDI = date(2026, 11, 11)  # il faut tenir mercredi, jeudi et vendredi


def _article(db: Session, name: str, category: str, unit: str, qty: str) -> StockArticle:
    art = StockArticle(
        name=name, category=category, unit=unit, out_mode="RECIPE",
        quantity=Decimal(qty), avg_cost_xof=Decimal(500), is_active=True,
    )
    db.add(art)
    db.flush()
    return art


def _sold(db: Session, art: StockArticle, day: date, qty: str) -> None:
    db.add(StockMovement(
        article_id=art.id, type="SALE_OUT", quantity=-Decimal(qty), quantity_after=Decimal(0),
        unit_cost_xof=Decimal(500), business_date=day, created_at=datetime.now(timezone.utc),
    ))


def test_stock_a_surveiller(db_session: Session) -> None:
    db = db_session
    open_days = [date(2026, 11, d) for d in (4, 5, 6, 9, 10)]  # 5 jours d'ouverture
    for day in [date(2026, 11, 3), *open_days]:
        db.add(CashSession(cash_register_id="reg-01", opened_by_user_id="usr-caissier-01",
                           business_date=day, status=CashSessionStatus.CLOSED, opening_float_xof=0))

    mouton = _article(db, "Mouton", "PROTEINE", "kg", "4.5")      # 1,5 kg/jour : 3 jours, OK
    poulet = _article(db, "Poulet", "PROTEINE", "pièce", "5")     # 2,5/jour : 2 jours, BAS
    saumon = _article(db, "Saumon", "PROTEINE", "morceau", "2")   # 4/jour : CRITIQUE
    sosso = _article(db, "Sosso", "PROTEINE", "pièce", "0")       # vendue cette semaine : RUPTURE
    carpe = _article(db, "Carpe", "PROTEINE", "pièce", "0")       # plus vendue : masquée
    _article(db, "Jus de bissap", "BOISSON", "bouteille", "50")   # pas de vente récente : OK
    gingembre = _article(db, "Jus de gingembre", "BOISSON", "bouteille", "12")  # 3/jour : 4 j < 5, BAS
    citron = _article(db, "Jus de citron", "BOISSON", "bouteille", "16")  # 3/jour : 5,3 j, OK
    orangina = _article(db, "Orangina 50 cl", "BOISSON", "bouteille", "6")  # 4/jour : BAS
    _article(db, "Riz", "EPICERIE", "kg", "1")                    # hors protéines et boissons

    # Mouton : 3,5 plats au kilo (fiche technique)
    cat = Category(name="Plats", kind="DISH")
    db.add(cat)
    db.flush()
    plat = Product(category_id=cat.id, name="Plat mouton", short_name="MOUTON", price_xof=3500)
    db.add(plat)
    db.flush()
    db.add(ProductComponent(product_id=plat.id, article_id=mouton.id, quantity=Decimal("0.286")))

    for day in open_days:
        _sold(db, mouton, day, "1.5")
        _sold(db, poulet, day, "2.5")
        _sold(db, saumon, day, "4")
        _sold(db, orangina, day, "4")
        _sold(db, gingembre, day, "3")
        _sold(db, citron, day, "3")
    _sold(db, sosso, date(2026, 11, 10), "3")
    _sold(db, carpe, date(2026, 10, 1), "1")  # il y a plus de 4 semaines
    _sold(db, mouton, MERCREDI, "9")  # les ventes du jour ne comptent pas dans la moyenne
    db.commit()

    out = stock_watch(db, MERCREDI)
    assert (out.next_market_date, out.open_days_to_market) == (date(2026, 11, 16), 3)
    assert out.average_days == open_days  # le 03/11, plus ancien, n'entre pas dans la moyenne

    got = {i.name: i for i in out.items}
    assert set(got) == {
        "Mouton", "Poulet", "Saumon", "Sosso", "Jus de bissap", "Orangina 50 cl",
        "Jus de gingembre", "Jus de citron",
    }
    assert [i.name for i in out.items] == [
        "Sosso", "Saumon", "Orangina 50 cl", "Poulet", "Jus de gingembre", "Mouton",
        "Jus de citron", "Jus de bissap",
    ]
    # Les jus à part : une semaine d'avance, même si le marché du lundi est dans 3 jours
    assert (got["Jus de gingembre"].group, got["Jus de gingembre"].level) == ("JUS", "BAS")
    assert (got["Jus de citron"].group, got["Jus de citron"].level) == ("JUS", "OK")
    assert (got["Orangina 50 cl"].group, got["Mouton"].group) == ("BOISSON", "PROTEINE")
    assert [got[n].level for n in ("Sosso", "Saumon", "Orangina 50 cl", "Poulet", "Mouton")] == [
        "RUPTURE", "CRITIQUE", "BAS", "BAS", "OK",
    ]
    assert (got["Mouton"].daily_sales, got["Mouton"].coverage_days) == (1.5, 3.0)
    assert got["Mouton"].dishes_left == 15  # 4,5 kg à 0,286 kg le plat
    assert got["Poulet"].dishes_left == 20  # portion standard : 4 plats par poulet
    assert got["Orangina 50 cl"].dishes_left is None  # une boisson n'a pas de plats
    assert got["Jus de bissap"].coverage_days is None
