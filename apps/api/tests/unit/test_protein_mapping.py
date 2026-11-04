"""Règle universelle du stock protéines (D6) : règles pures."""

from decimal import Decimal

from caisse.domain import stock_rules
from caisse.domain.protein_mapping import (
    article_protein_key,
    dish_variant,
    match_protein_keyword,
    standard_portion,
)


def test_ledger_bucket_classe_chaque_mouvement() -> None:
    b = stock_rules.ledger_bucket
    assert b("PURCHASE_IN", False) == stock_rules.LEDGER_PURCHASES
    assert b("SALE_OUT", True) == stock_rules.LEDGER_SALES
    assert b("RETURN_IN", True) == stock_rules.LEDGER_SALES
    # sortie « vente » sans commande (rattrapage de migration) : correction, pas vente
    assert b("SALE_OUT", False) == stock_rules.LEDGER_CORRECTIONS
    assert b("ADJUSTMENT", False) == stock_rules.LEDGER_CORRECTIONS
    assert b("LOSS_OUT", False) == stock_rules.LEDGER_LOSSES
    assert b("INVENTORY_COUNT", False) == stock_rules.LEDGER_INVENTORY
    assert b("OPENING", False) == stock_rules.LEDGER_OPENING


def test_standard_portion_prend_la_portion_la_plus_frequente() -> None:
    q = Decimal
    assert standard_portion([q("0.25"), q("0.5"), q("0.25")], "POULET") == q("0.25")
    # égalité : la plus petite
    assert standard_portion([q("0.5"), q("0.25")], "POULET") == q("0.25")
    # sans fiche : barème par défaut, sinon 1
    assert standard_portion([], "MOUTON") == q("0.286")
    assert standard_portion([], None) == q("1.000")


def test_rattachement_par_libelle() -> None:
    assert match_protein_keyword("Tchep+Saumon") == "FAUX_SAUMON"
    assert match_protein_keyword("Foutou+ Faux saumon") == "FAUX_SAUMON"
    assert match_protein_keyword("Sauce feuille + bro") == "FAUX_BROCHET"
    assert match_protein_keyword("Poulet pondeuse braisé") == "POULET_PONDEUSE"
    assert match_protein_keyword("Bœuf sauce graine") == "BOEUF"
    assert match_protein_keyword("Glossaire") is None  # pas « loss » isolé
    assert match_protein_keyword("Attiéké") is None
    assert article_protein_key("Saumon") == "FAUX_SAUMON"
    assert article_protein_key("Bœuf") == "BOEUF"
    assert dish_variant("Foufou sauce claire + Saumon") == "foufou"
    assert dish_variant("Foutou+ Saumon") == "foutou"
    assert dish_variant("Tchep+Saumon") == "normal"
