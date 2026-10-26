from decimal import Decimal
import pytest

from caisse.domain.recipe_rules import match_protein_for_product, PROTEIN_PORTIONS


def test_match_protein_boeuf_variations():
    assert match_protein_for_product("Riz sauce claire + Bœuf") == ("Bœuf", Decimal("0.200"))
    assert match_protein_for_product("Tchep + Boeuf") == ("Bœuf", Decimal("0.200"))
    assert match_protein_for_product("Foutou + Pistache bœuf") == ("Bœuf", Decimal("0.200"))
    assert match_protein_for_product("Dah riz + Bœuf") == ("Bœuf", Decimal("0.200"))


def test_match_protein_mouton():
    assert match_protein_for_product("Foutou graine + Mouton") == ("Mouton", Decimal("0.286"))
    assert match_protein_for_product("Plat mouton") == ("Mouton", Decimal("0.286"))


def test_match_protein_poulet_and_pondeuse():
    assert match_protein_for_product("Riz pistache + Poulet") == ("Poulet", Decimal("0.250"))
    assert match_protein_for_product("Kedjenou") == ("Poulet pondeuse", Decimal("0.250"))
    assert match_protein_for_product("Kedjenou poulet pondeuse") == ("Poulet pondeuse", Decimal("0.250"))


def test_match_protein_poissons():
    assert match_protein_for_product("Sosso 4000") == ("Sosso", Decimal("1.000"))
    assert match_protein_for_product("Tchep + Sosso 3500") == ("Sosso", Decimal("1.000"))
    assert match_protein_for_product("Carpe 5000") == ("Carpe", Decimal("1.000"))
    assert match_protein_for_product("Foufou/foutou faux brochet") == ("Faux brochet", Decimal("1.000"))
    assert match_protein_for_product("Loss 3500") == ("Loss", Decimal("1.000"))
    assert match_protein_for_product("Faux saumon") == ("Faux saumon", Decimal("1.000"))


def test_match_protein_no_protein():
    assert match_protein_for_product("Alloco") is None
    assert match_protein_for_product("Attiéké seul") is None
    assert match_protein_for_product("Eau Celeste 1,5 L") is None
    assert match_protein_for_product("") is None
