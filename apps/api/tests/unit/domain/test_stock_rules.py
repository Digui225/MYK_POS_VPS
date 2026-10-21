from decimal import Decimal as D

from caisse.domain.stock_rules import (
    is_below_threshold,
    is_stock_low,
    portions_available,
    value_xof,
    weighted_average_cost,
)


def test_weighted_average_cost() -> None:
    # 10 kg à 4 000 + 5 kg à 4 600 = 63 000 pour 15 kg
    assert weighted_average_cost(D(10), D(4000), D(5), D(4600)) == D("4200.00")
    # stock nul ou négatif : le prix d'achat devient la référence
    assert weighted_average_cost(D(0), D(4000), D(3), D(4500)) == D("4500.00")
    assert weighted_average_cost(D(-2), D(4000), D(3), D(4500)) == D("4500.00")
    # pas d'entrée : coût inchangé
    assert weighted_average_cost(D(5), D(300), D(0), D(999)) == D(300)
    # arrondi au centime (eau 0,5 L : pack de 9 à 1 000)
    assert weighted_average_cost(D(0), D(0), D(9), D(1000) / D(9)) == D("111.11")


def test_portions_available() -> None:
    assert portions_available([]) is None
    # 8 kg de mouton à 0,27 kg par plat : 29 plats
    assert portions_available([(D("0.27"), D(8))]) == D(29)
    # le composant le plus rare décide, jamais négatif
    assert portions_available([(D(1), D(5)), (D("0.25"), D("0.5"))]) == D(2)
    assert portions_available([(D(1), D(-3))]) == D(0)


def test_value_and_threshold() -> None:
    assert value_xof(D("0.2"), D("4000")) == 800
    assert value_xof(D("-1.5"), D("111.11")) == -167
    assert is_below_threshold(D(-1), None)
    assert not is_below_threshold(D(3), None)
    assert is_below_threshold(D(3), D(3))
    assert not is_below_threshold(D("3.001"), D(3))


def test_is_stock_low():
    assert is_stock_low(current_qty := 3.0, alert_threshold := 5.0) is True
    assert is_stock_low(5.0, 5.0) is True
    assert is_stock_low(-1.0, 5.0) is True
    assert is_stock_low(10.0, 5.0) is False

