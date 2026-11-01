import pytest

from caisse.domain.session_rules import (
    calculate_counted_cash,
    calculate_variance,
    validate_business_date,
    validate_opening_float,
)
from caisse.errors import CaisseException


def test_validate_business_date_valid():
    d = validate_business_date("2026-09-28")
    assert d.year == 2026
    assert d.month == 9
    assert d.day == 28


def test_validate_business_date_invalid_format():
    with pytest.raises(CaisseException) as exc:
        validate_business_date("28/09/2026")
    assert exc.value.code == "INVALID_BUSINESS_DATE_FORMAT"


def test_validate_opening_float_valid():
    validate_opening_float(20000)
    validate_opening_float(0)


def test_validate_opening_float_negative():
    with pytest.raises(CaisseException) as exc:
        validate_opening_float(-500)
    assert exc.value.code == "NEGATIVE_OPENING_FLOAT"


def test_calculate_counted_cash():
    breakdown = {
        "10000": 10,
        "5000": 4,
        "2000": 5,
        "1000": 10,
        "500": 20,
        "coin_500": 2,
        "coin_200": 5,
    }
    # 100 000 + 20 000 + 10 000 + 10 000 + 10 000 + 1 000 + 1 000 = 152 000
    total = calculate_counted_cash(breakdown)
    assert total == 152000


def test_calculate_counted_cash_negative_count():
    with pytest.raises(CaisseException) as exc:
        calculate_counted_cash({"10000": -1})
    assert exc.value.code == "NEGATIVE_DENOMINATION_COUNT"


def test_calculate_variance():
    # Compté 148 000 pour 150 000 attendu = écart de -2 000 XOF
    variance = calculate_variance(expected_cash_xof=150000, counted_cash_xof=148000)
    assert variance == -2000

    # Compté 151 000 pour 150 000 attendu = surplus de +1 000 XOF
    variance_plus = calculate_variance(expected_cash_xof=150000, counted_cash_xof=151000)
    assert variance_plus == 1000
