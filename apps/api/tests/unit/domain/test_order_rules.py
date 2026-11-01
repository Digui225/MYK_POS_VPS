from types import SimpleNamespace

import pytest

from caisse.domain.enums import OrderStatus
from caisse.domain.order_rules import (
    assert_order_editable,
    calculate_line_total,
    generate_order_number,
    recalculate_order_totals,
)
from caisse.errors import CaisseException


def test_generate_order_number():
    num = generate_order_number("2026-09-28", 42)
    assert num == "2026-09-28-0042"

    num1 = generate_order_number("2026-09-28", 1)
    assert num1 == "2026-09-28-0001"


def test_assert_order_editable_open():
    assert_order_editable(OrderStatus.OPEN)
    assert_order_editable(OrderStatus.PARTIALLY_PAID)


def test_assert_order_editable_closed_raises():
    with pytest.raises(CaisseException) as exc:
        assert_order_editable(OrderStatus.PAID)
    assert exc.value.code == "ORDER_NOT_EDITABLE"
    assert exc.value.status_code == 409

    with pytest.raises(CaisseException) as exc:
        assert_order_editable(OrderStatus.CANCELLED)
    assert exc.value.code == "ORDER_NOT_EDITABLE"


def test_calculate_line_total_valid():
    assert calculate_line_total(1500, 2) == 3000
    assert calculate_line_total(0, 1) == 0


def test_calculate_line_total_negative_price():
    with pytest.raises(CaisseException) as exc:
        calculate_line_total(-100, 2)
    assert exc.value.code == "INVALID_UNIT_PRICE"


def test_calculate_line_total_invalid_quantity():
    with pytest.raises(CaisseException) as exc:
        calculate_line_total(1500, 0)
    assert exc.value.code == "INVALID_QUANTITY"

    with pytest.raises(CaisseException) as exc:
        calculate_line_total(1500, -2)
    assert exc.value.code == "INVALID_QUANTITY"


def test_recalculate_order_totals_with_active_and_removed_items():
    items = [
        SimpleNamespace(unit_price_xof=5000, quantity=2, vat_rate=18.0, removed_at=None), # 10000 TTC
        SimpleNamespace(unit_price_xof=1000, quantity=1, vat_rate=18.0, removed_at=None), # 1000 TTC
        SimpleNamespace(unit_price_xof=4000, quantity=1, vat_rate=18.0, removed_at="2026-09-28T12:00:00Z"), # Removed!
    ]

    total_ttc, total_ht, total_vat = recalculate_order_totals(items)
    # Total TTC = 10000 + 1000 = 11000
    assert total_ttc == 11000
    assert total_ttc == total_ht + total_vat
    assert total_vat > 0
