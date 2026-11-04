"""Règle unique de rattachement d'un plat à l'une des 9 protéines (D6, MEMORY.md).

Un plat consomme d'abord ce que dit sa fiche technique. Les plats sans fiche protéine
(saisie libre « Hors Menu », plat non répertorié) sont rattachés par mot-clé de leur libellé,
avec la portion standard de la protéine. Ces règles servent partout : déstockage à la vente,
matrice de contrôle, estimation des sorties cuisine, rapport des rendements.
"""

import re
import unicodedata
from collections import Counter
from collections.abc import Iterable
from decimal import Decimal

PROTEIN_KEYS: tuple[str, ...] = (
    "POULET_PONDEUSE",
    "POULET",
    "FAUX_BROCHET",
    "FAUX_SAUMON",
    "SOSSO",
    "LOSS",
    "MOUTON",
    "BOEUF",
    "CARPE",
)

# Portion consommée par plat quand aucune fiche technique de la protéine n'existe
DEFAULT_PROTEIN_PORTION: dict[str, Decimal] = {
    "BOEUF": Decimal("0.200"),
    "MOUTON": Decimal("0.286"),
    "POULET": Decimal("0.250"),
    "POULET_PONDEUSE": Decimal("0.250"),
    "FAUX_BROCHET": Decimal("1.000"),
    "FAUX_SAUMON": Decimal("1.000"),
    "SOSSO": Decimal("1.000"),
    "LOSS": Decimal("1.000"),
    "CARPE": Decimal("1.000"),
}


def normalize_dish_name(name: str | None) -> str:
    """Minuscules, sans accents, sans ligature."""
    if not name:
        return ""
    n = name.lower().replace("œ", "oe")
    return unicodedata.normalize("NFKD", n).encode("ascii", "ignore").decode("ascii")


def match_protein_keyword(name: str | None) -> str | None:
    """Clé de la protéine citée dans un libellé de plat, ou `None`.
    L'ordre compte : « pondeuse » avant « poulet », brochet avant saumon, etc."""
    n = normalize_dish_name(name)
    if not n:
        return None
    if "pondeuse" in n:
        return "POULET_PONDEUSE"
    if "poulet" in n or "chair" in n:
        return "POULET"
    if (
        re.search(r"\bbrochet\b", n)
        or "machoiran" in n
        or "faux bro" in n
        or re.search(r"\bbro\b", n)
        or "+bro" in n
    ):
        return "FAUX_BROCHET"
    if "saumon" in n:
        return "FAUX_SAUMON"
    if "sosso" in n:
        return "SOSSO"
    if re.search(r"\bloss\b", n):
        return "LOSS"
    if "mouton" in n:
        return "MOUTON"
    if "boeuf" in n:
        return "BOEUF"
    if "carpe" in n:
        return "CARPE"
    return None


def article_protein_key(article_name: str | None) -> str | None:
    """Clé de la protéine que représente un article de stock (d'après son nom)."""
    n = normalize_dish_name(article_name)
    if not n:
        return None
    if "pondeuse" in n:
        return "POULET_PONDEUSE"
    if "poulet" in n:
        return "POULET"
    if "brochet" in n or "machoiran" in n:
        return "FAUX_BROCHET"
    if "saumon" in n:
        return "FAUX_SAUMON"
    if "sosso" in n:
        return "SOSSO"
    if "loss" in n:
        return "LOSS"
    if "mouton" in n:
        return "MOUTON"
    if "boeuf" in n:
        return "BOEUF"
    if "carpe" in n:
        return "CARPE"
    return None


def standard_portion(recipe_quantities: Iterable[Decimal], protein_key: str | None) -> Decimal:
    """Portion standard d'une protéine : la quantité la plus fréquente de ses fiches techniques
    (la plus petite en cas d'égalité), sinon le barème par défaut, sinon 1."""
    counts = Counter(q for q in recipe_quantities if q > 0)
    if counts:
        best = max(counts.values())
        return min(q for q, c in counts.items() if c == best)
    if protein_key is not None:
        return DEFAULT_PROTEIN_PORTION.get(protein_key, Decimal("1.000"))
    return Decimal("1.000")


def dish_variant(name: str | None) -> str:
    """« foufou », « foutou » ou « normal », pour la ventilation des plats vendus."""
    n = normalize_dish_name(name)
    if "foufou" in n:
        return "foufou"
    if "foutou" in n:
        return "foutou"
    return "normal"
