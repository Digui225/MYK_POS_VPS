import math
from decimal import Decimal

from caisse.domain.money import (
    calculate_change,
    calculate_vat_split,
    to_unit_rate,
    to_xof,
)


def test_calculate_vat_split_zero_or_negative():
    assert calculate_vat_split(0, 18.0) == (0, 0)
    assert calculate_vat_split(-1000, 18.0) == (0, 0)


def test_calculate_vat_split_rate_zero():
    assert calculate_vat_split(10000, 0) == (10000, 0)
    assert calculate_vat_split(10000, 0.0) == (10000, 0)


def test_calculate_vat_split_standard_18():
    # 11 800 TTC à 18% -> 10 000 HT et 1 800 TVA
    ht, vat = calculate_vat_split(11800, 18.0)
    assert ht == 10000
    assert vat == 1800
    assert ht + vat == 11800


def test_calculate_vat_split_rounding_half_up():
    # 3500 TTC à 18% -> 3500 / 1.18 = 2966.1016... -> HT = 2966, TVA = 534
    ht, vat = calculate_vat_split(3500, 18.0)
    assert ht == 2966
    assert vat == 534
    assert ht + vat == 3500


def test_calculate_vat_split_non_regression_1_to_100000():
    """Garantit une stricte équivalence entre l'ancienne formule float et la formule Decimal."""
    rate = 18.0
    factor = 1.0 + (rate / 100.0)
    for ttc in range(1, 100001):
        expected_ht = int(math.floor((ttc / factor) + 0.5))
        expected_vat = ttc - expected_ht
        actual_ht, actual_vat = calculate_vat_split(ttc, rate)
        assert (actual_ht, actual_vat) == (expected_ht, expected_vat), f"Écart sur {ttc} XOF"


def test_to_xof():
    assert to_xof(Decimal("100.49")) == 100
    assert to_xof(Decimal("100.50")) == 101
    assert to_xof(100) == 100
    assert to_xof(100.5) == 101


def test_to_unit_rate():
    assert to_unit_rate(Decimal("12.3456")) == 12.35
    assert to_unit_rate(Decimal("12.3444")) == 12.34
    assert to_unit_rate(12.345) == 12.35
    assert to_unit_rate(15) == 15.0


def test_calculate_change():
    assert calculate_change(None, 5000) == 0
    assert calculate_change(4000, 5000) == 0
    assert calculate_change(5000, 5000) == 0
    assert calculate_change(10000, 6500) == 3500
