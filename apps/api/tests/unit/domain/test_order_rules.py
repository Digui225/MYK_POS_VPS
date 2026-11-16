from types import SimpleNamespace

import pytest

from caisse.core.errors import CaisseException
from caisse.domain.enums import OrderStatus
from caisse.domain.order_rules import (
    assert_order_cancellable,
    assert_order_editable,
    calculate_line_total,
    generate_order_number,
    recalculate_order_totals,
)


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


# --- Annulation d'une commande à la caisse ---------------------------------------------------

def _cancel_error(**kwargs: object) -> str | None:
    params = {"has_payment": False, "active_total_xof": 0, "role": "CAISSIER", **kwargs}
    status = str(params.pop("status", "OPEN"))
    try:
        assert_order_cancellable(status, **params)  # type: ignore[arg-type]
    except CaisseException as exc:
        return exc.code
    return None


def test_cashier_cancels_an_empty_order() -> None:
    assert _cancel_error() is None


def test_cashier_needs_a_manager_when_items_remain() -> None:
    assert _cancel_error(active_total_xof=3000) == "ORDER_CANCEL_REQUIRES_MANAGER"
    assert _cancel_error(active_total_xof=3000, role="RESPONSABLE") is None
    assert _cancel_error(active_total_xof=3000, role="ADMIN") is None


def test_no_cancel_after_a_payment_even_for_a_manager() -> None:
    assert _cancel_error(has_payment=True, role="ADMIN") == "ORDER_HAS_PAYMENTS"
    assert _cancel_error(status="PARTIALLY_PAID", role="ADMIN") == "ORDER_HAS_PAYMENTS"


def test_no_cancel_of_a_closed_order() -> None:
    assert _cancel_error(status="PAID", role="ADMIN") == "ORDER_NOT_EDITABLE"
    assert _cancel_error(status="CANCELLED", role="ADMIN") == "ORDER_NOT_EDITABLE"
