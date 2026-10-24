import pytest

from caisse.domain.market_budget_rules import (
    calculate_market_budget_status,
    validate_market_budget,
)
from caisse.errors import MarketBudgetExceededError


def test_budget_status_empty_basket():
    status = calculate_market_budget_status(0, role="ECONOME")
    assert status["is_exceeded"] is False
    assert status["percentage"] == 0
    assert status["color_class"] == "slate"
    assert "vide" in status["level_text"].lower()
    # Confidentialité : aucun montant pour l'économe
    assert "total_budget_xof" not in status
    assert "total_limit_xof" not in status


def test_budget_status_standard_capacity():
    # 50 000 / 145 000 = ~34.5% (< 70%)
    status = calculate_market_budget_status(50_000, role="ECONOME")
    assert status["is_exceeded"] is False
    assert status["percentage"] == 34
    assert status["color_class"] == "emerald"
    assert "total_budget_xof" not in status


def test_budget_status_high_level():
    # 120 000 / 145 000 = ~82.7% (>= 70% et <= 100%)
    status = calculate_market_budget_status(120_000, role="ECONOME")
    assert status["is_exceeded"] is False
    assert status["percentage"] == 82
    assert status["color_class"] == "amber"
    assert "élevé" in status["level_text"].lower() or "proche" in status["level_text"].lower()


def test_budget_status_exceeded_for_econome():
    # 150 000 > 145 000
    status = calculate_market_budget_status(150_000, role="ECONOME")
    assert status["is_exceeded"] is True
    assert status["color_class"] == "rose"
    assert "bloquée" in status["level_text"].lower() or "dépassé" in status["level_text"].lower()


def test_budget_status_full_breakdown_for_responsable():
    status = calculate_market_budget_status(100_000, role="RESPONSABLE")
    assert status["total_budget_xof"] == 100_000
    assert status["total_limit_xof"] == 300_000
    assert status["econome_limit_xof"] == 145_000
    assert status["remaining_budget_xof"] == 200_000


def test_validate_market_budget_success_for_econome():
    validate_market_budget(140_000, role="ECONOME")


def test_validate_market_budget_fails_when_econome_exceeds_limit():
    with pytest.raises(MarketBudgetExceededError):
        validate_market_budget(145_001, role="ECONOME")


def test_validate_market_budget_allows_responsable_within_total_limit():
    # Responsable peut dépasser le seuil économe (145 000) jusqu'au plafond (300 000)
    validate_market_budget(250_000, role="RESPONSABLE")


def test_validate_market_budget_fails_when_total_limit_exceeded_for_anyone():
    with pytest.raises(MarketBudgetExceededError) as exc_info:
        validate_market_budget(300_001, role="RESPONSABLE")
    assert exc_info.value.code == "MARKET_BUDGET_EXCEEDED"
    assert "300" in exc_info.value.detail
