from decimal import Decimal

import pytest

from caisse.domain.production_rules import (
    calculate_dish_variance,
    calculate_financial_impact,
    calculate_item_total,
    calculate_theoretical_dishes,
)


def test_calculate_item_total():
    # 5 kg à 4 000 FCFA/kg = 20 000 FCFA
    assert calculate_item_total(Decimal("5"), 4000) == 20000
    # 2.5 kg à 4 000 FCFA/kg = 10 000 FCFA
    assert calculate_item_total(Decimal("2.5"), 4000) == 10000
    # 10 poulets à 3 000 FCFA = 30 000 FCFA
    assert calculate_item_total(Decimal("10"), 3000) == 30000


def test_calculate_item_total_invalid():
    with pytest.raises(ValueError):
        calculate_item_total(Decimal("-1"), 4000)
    with pytest.raises(ValueError):
        calculate_item_total(Decimal("5"), -100)


def test_calculate_theoretical_dishes():
    # 3 poulets avec rendement de 4 plats/poulet = 12 plats prévus
    assert calculate_theoretical_dishes(Decimal("3"), Decimal("4")) == 12
    # 5 kg de boeuf avec rendement de 5 plats/kg = 25 plats prévus
    assert calculate_theoretical_dishes(Decimal("5"), Decimal("5")) == 25
    # 10 kg de mouton avec rendement de 3 plats/kg = 30 plats
    assert calculate_theoretical_dishes(Decimal("10"), Decimal("3")) == 30
    # Arrondi si fraction
    assert calculate_theoretical_dishes(Decimal("2.5"), Decimal("3")) == 8


def test_calculate_theoretical_dishes_invalid():
    with pytest.raises(ValueError):
        calculate_theoretical_dishes(Decimal("-1"), Decimal("4"))
    with pytest.raises(ValueError):
        calculate_theoretical_dishes(Decimal("3"), Decimal("0"))


def test_calculate_dish_variance_and_impact():
    # Exemple tableau blanc : 12 plats prévus, 10 vendus à 3 000 F/plat
    # Écart = 10 - 12 = -2 plats
    # Impact = 2 * 3 000 = 6 000 FCFA
    variance = calculate_dish_variance(sold_dishes=10, theoretical_dishes=12)
    assert variance == -2
    impact = calculate_financial_impact(variance_dishes=variance, dish_price_xof=3000)
    assert impact == 6000

    # Ventes conformes
    assert calculate_dish_variance(12, 12) == 0
    assert calculate_financial_impact(0, 3000) == 0

    # Ventes supérieures aux prévisions
    var_positive = calculate_dish_variance(14, 12)
    assert var_positive == 2
    assert calculate_financial_impact(var_positive, 3000) == 0


def test_match_protein_keyword():
    from caisse.domain.production_rules import match_protein_keyword

    # Plats réels du ticket Z
    assert match_protein_keyword("Riz dah+ Sosso") == "SOSSO"
    assert match_protein_keyword("Attieke+Sosso") == "SOSSO"
    assert match_protein_keyword("Tchep+Saumon") == "FAUX_SAUMON"
    assert match_protein_keyword("Saumon") == "FAUX_SAUMON"
    assert match_protein_keyword("Foutou+ Brochet") == "FAUX_BROCHET"
    assert match_protein_keyword("Plat brochet") == "FAUX_BROCHET"
    assert match_protein_keyword("Foutou+ Faux brochet") == "FAUX_BROCHET"
    assert match_protein_keyword("Riz graine+ Faux brochet") == "FAUX_BROCHET"
    assert match_protein_keyword("Dah+Faux brochet") == "FAUX_BROCHET"
    assert match_protein_keyword("Alloco + Mouton") == "MOUTON"
    assert match_protein_keyword("Tchep+Loss") == "LOSS"
    assert match_protein_keyword("Légumes riz + Loss") == "LOSS"

    # Poulet par défaut = POULET (chair), pondeuse = POULET_PONDEUSE
    assert match_protein_keyword("Riz graine + Poulet") == "POULET"
    assert match_protein_keyword("Poulet chair braisé") == "POULET"
    assert match_protein_keyword("Poulet chaire") == "POULET"
    assert match_protein_keyword("Poulet pondeuse braisé") == "POULET_PONDEUSE"
    assert match_protein_keyword("Pondeuse sauce graine") == "POULET_PONDEUSE"

    # Boeuf avec et sans ligature
    assert match_protein_keyword("Sauce Feuille + Boeuf") == "BOEUF"
    assert match_protein_keyword("Sauce Feuille + Bœuf") == "BOEUF"

    # Carpe
    assert match_protein_keyword("Carpe braisée") == "CARPE"

    # Boissons et accompagnements hors protéine
    assert match_protein_keyword("Eau celeste") is None
    assert match_protein_keyword("Riz") is None
    assert match_protein_keyword("Expresso") is None
    assert match_protein_keyword("") is None

