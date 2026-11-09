"""Stock à surveiller : le stock doit tenir jusqu'au prochain marché (le lundi)."""

from datetime import date
from decimal import Decimal

from caisse.domain.stock_watch_rules import (
    StockWatchGroup,
    StockWatchLevel,
    coverage_days,
    days_to_cover,
    is_hidden,
    level,
    next_market,
    open_days_to_market,
    watch_group,
)

LUNDI, MERCREDI, VENDREDI, SAMEDI = date(2026, 11, 9), date(2026, 11, 11), date(2026, 11, 13), date(2026, 11, 14)


def test_prochain_marche_et_jours_a_couvrir() -> None:
    assert next_market(LUNDI) == date(2026, 11, 16)
    assert next_market(VENDREDI) == date(2026, 11, 16)
    assert next_market(SAMEDI) == date(2026, 11, 16)
    assert [open_days_to_market(d) for d in (LUNDI, MERCREDI, VENDREDI, SAMEDI)] == [5, 3, 1, 0]


def test_niveaux_selon_la_couverture() -> None:
    # Mercredi : il faut tenir 3 jours (mercredi, jeudi, vendredi)
    assert level(Decimal(0), Decimal(4), 3) == StockWatchLevel.RUPTURE
    assert level(Decimal(3), Decimal(4), 3) == StockWatchLevel.CRITIQUE  # moins d'une journée
    assert level(Decimal(8), Decimal(4), 3) == StockWatchLevel.BAS  # 2 jours sur 3
    assert level(Decimal(12), Decimal(4), 3) == StockWatchLevel.OK  # tient jusqu'au lundi
    assert level(Decimal(5), Decimal(0), 3) == StockWatchLevel.OK  # pas de vente récente
    assert coverage_days(Decimal(8), Decimal(4)) == 2
    assert coverage_days(Decimal(8), Decimal(0)) is None


def test_article_a_zero_qu_on_ne_vend_plus_masque() -> None:
    assert is_hidden(Decimal(0), sold_recently=False)
    assert not is_hidden(Decimal(0), sold_recently=True)  # rupture d'un article vendu : visible
    assert not is_hidden(Decimal(3), sold_recently=False)  # réapprovisionné : il revient


def test_les_jus_a_part_une_semaine_d_avance() -> None:
    assert watch_group("BOISSON", "Jus de bissap") == StockWatchGroup.JUS
    assert watch_group("BOISSON", "jus Tomy") == StockWatchGroup.JUS
    assert watch_group("BOISSON", "Orangina 50 cl") == StockWatchGroup.BOISSON
    assert watch_group("PROTEINE", "Mouton") == StockWatchGroup.PROTEINE
    # Le vendredi, il suffit de tenir la journée ; un jus doit tenir une semaine
    assert days_to_cover(StockWatchGroup.BOISSON, VENDREDI) == 1
    assert days_to_cover(StockWatchGroup.JUS, VENDREDI) == 5
    assert days_to_cover(StockWatchGroup.JUS, SAMEDI) == 5
