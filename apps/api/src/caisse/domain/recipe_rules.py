"""Règles pures pour les fiches techniques des plats et la détection automatique
des portions des 9 protéines du restaurant."""

import re
from decimal import Decimal

PROTEIN_PORTIONS: dict[str, Decimal] = {
    "Bœuf": Decimal("0.200"),
    "Mouton": Decimal("0.286"),
    "Poulet": Decimal("0.250"),
    "Poulet pondeuse": Decimal("0.250"),
    "Sosso": Decimal("1.000"),
    "Carpe": Decimal("1.000"),
    "Brochet": Decimal("1.000"),
    "Loss": Decimal("1.000"),
    "Saumon": Decimal("1.000"),
    # Rétrocompatibilité
    "Faux brochet": Decimal("1.000"),
    "Faux saumon": Decimal("1.000"),
}


def match_protein_for_product(product_name: str) -> tuple[str, Decimal] | None:
    """Détecte si le nom d'un plat mentionne l'une des 9 protéines principales du restaurant
    et retourne (nom_article_proteine, quantite_portion).

    Gère les variantes orthographiques courantes (ex: 'boeuf' ou 'bœuf', pondeuse/kedjenou).
    Retourne None si le plat n'est pas lié à une protéine standard.
    """
    if not product_name:
        return None

    norm = product_name.strip().lower()

    # Bœuf : gère 'boeuf' et 'bœuf' (ligature œ)
    if "boeuf" in norm or "bœuf" in norm:
        return ("Bœuf", PROTEIN_PORTIONS["Bœuf"])

    # Mouton
    if "mouton" in norm:
        return ("Mouton", PROTEIN_PORTIONS["Mouton"])

    # Poulet pondeuse (ex: Kedjenou ou mention explicite pondeuse)
    if "pondeuse" in norm or "kedjenou" in norm:
        return ("Poulet pondeuse", PROTEIN_PORTIONS["Poulet pondeuse"])

    # Poulet standard
    if "poulet" in norm:
        return ("Poulet", PROTEIN_PORTIONS["Poulet"])

    # Poissons
    if "sosso" in norm:
        return ("Sosso", PROTEIN_PORTIONS["Sosso"])
    # Carpe : la carpe sert uniquement au poisson braisé ou à la mention explicite "carpe"
    if "carpe" in norm:
        return ("Carpe", PROTEIN_PORTIONS["Carpe"])
    if "poisson" in norm and ("braisé" in norm or "braise" in norm):
        return ("Carpe", PROTEIN_PORTIONS["Carpe"])
    if (
        bool(re.search(r"\bbrochet\b", norm))
        or "machoiran" in norm
        or "faux bro" in norm
        or bool(re.search(r"\bbro\b", norm))
        or "+bro" in norm
    ):
        return ("Brochet", PROTEIN_PORTIONS["Brochet"])
    if "loss" in norm:
        return ("Loss", PROTEIN_PORTIONS["Loss"])
    if "saumon" in norm:
        return ("Saumon", PROTEIN_PORTIONS["Saumon"])

    return None

