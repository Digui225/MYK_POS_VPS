"""Règles métier pures pour la gestion des achats de marché, de la production cuisine
et du contrôle des rendements et écarts de portions."""

from decimal import Decimal


def calculate_item_total(quantity: Decimal, unit_price_xof: int) -> int:
    """Calcule le coût total d'une ligne d'achat (arrondi à l'entier XOF).
    Lève ValueError si la quantité ou le prix unitaire est négatif."""
    if quantity < Decimal(0):
        raise ValueError("La quantité ne peut pas être négative")
    if unit_price_xof < 0:
        raise ValueError("Le prix unitaire ne peut pas être négatif")
    return int(round(quantity * Decimal(unit_price_xof)))


def calculate_theoretical_dishes(
    prepared_quantity: Decimal, yield_portions_per_unit: Decimal
) -> int:
    """Calcule le nombre théorique de plats prévus d'après la matière sortie et son rendement.
    Ex: 3 poulets * 4 plats/poulet = 12 plats.
    Lève ValueError si les valeurs sont inférieures ou égales à zéro."""
    if prepared_quantity < Decimal(0):
        raise ValueError("La quantité préparée ne peut pas être négative")
    if yield_portions_per_unit <= Decimal(0):
        raise ValueError("Le rendement par unité doit être strictement supérieur à zéro")
    return int(round(prepared_quantity * yield_portions_per_unit))


def calculate_dish_variance(sold_dishes: int, theoretical_dishes: int) -> int:
    """Calcule l'écart en plats : Plats réellement vendus - Plats théoriques prévus.
    Un écart négatif indique un déficit (portions invendues, non saisies ou perdues)."""
    return sold_dishes - theoretical_dishes


def calculate_financial_impact(variance_dishes: int, dish_price_xof: int) -> int:
    """Valorise l'écart en FCFA au prix de vente du plat.
    Ne s'applique que si variance_dishes < 0 (déficit de portions vendues)."""
    if variance_dishes >= 0:
        return 0
    if dish_price_xof < 0:
        raise ValueError("Le prix du plat ne peut pas être négatif")
    return abs(variance_dishes) * dish_price_xof


def normalize_dish_name(name: str) -> str:
    """Normalise un nom de plat (minuscules, sans accents, sans ligature)."""
    if not name:
        return ""
    import unicodedata

    n = name.lower().replace("œ", "oe")
    return (
        unicodedata.normalize("NFKD", n)
        .encode("ascii", "ignore")
        .decode("ascii")
    )


def match_protein_keyword(name: str) -> str | None:
    """Détecte le mot-clé de protéine dans un libellé de plat (saisie libre ou plat non répertorié).
    Retourne la clé canonique de la protéine :
    'POULET_PONDEUSE', 'POULET', 'BOEUF', 'MOUTON', 'SOSSO', 'FAUX_BROCHET', 'FAUX_SAUMON', 'LOSS', 'CARPE'
    ou None si aucune protéine reconnue."""
    import re

    n = normalize_dish_name(name)
    if not n:
        return None

    # 1. Pondeuse prioritaire sur Poulet
    if "pondeuse" in n:
        return "POULET_PONDEUSE"

    # 2. Poulet chair (par défaut quand 'poulet' ou 'chair' ou 'chaire' est mentionné)
    if "poulet" in n or "chair" in n:
        return "POULET"

    # 3. Faux brochet (machoiran, brochet)
    if "brochet" in n or "machoiran" in n:
        return "FAUX_BROCHET"

    # 4. Faux saumon
    if "saumon" in n:
        return "FAUX_SAUMON"

    # 5. Sosso
    if "sosso" in n:
        return "SOSSO"

    # 6. Loss (\bloss\b pour éviter faux positifs)
    if re.search(r"\bloss\b", n):
        return "LOSS"

    # 7. Mouton
    if "mouton" in n:
        return "MOUTON"

    # 8. Bœuf / Boeuf
    if "boeuf" in n:
        return "BOEUF"

    # 9. Carpe
    if "carpe" in n:
        return "CARPE"

    return None

