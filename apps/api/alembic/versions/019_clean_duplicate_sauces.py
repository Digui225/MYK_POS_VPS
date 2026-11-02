"""clean_duplicate_sauces

Revision ID: 019_clean_duplicate_sauces
Revises: 018_fne_point_of_sale_setting
Create Date: 2026-11-02 15:15:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "019_clean_duplicate_sauces"
down_revision: Union[str, None] = "018_fne_point_of_sale_setting"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    products_table = sa.table(
        "products",
        sa.column("id", sa.String),
        sa.column("sku", sa.String),
        sa.column("name", sa.String),
        sa.column("short_name", sa.String),
        sa.column("price_xof", sa.Integer),
        sa.column("is_active", sa.Boolean),
    )

    # 1. Désactiver les doublons "... riz" et le doublon "Kabato Dah + Bœuf"
    # Les SKUs SYL-122 à SYL-134 sont les doublons réimportés
    duplicate_skus = [
        "SYL-122",  # Dah riz + Poulet
        "SYL-123",  # Dah riz + Bœuf
        "SYL-124",  # Dah riz + Mouton
        "SYL-125",  # Dah riz + Poisson
        "SYL-126",  # Kabato Dah + Bœuf (doublon de SYL-008 Kabato Dah + Boeuf)
        "SYL-127",  # Feuille riz + Poulet
        "SYL-128",  # Feuille riz + Bœuf
        "SYL-129",  # Feuille riz + Mouton
        "SYL-130",  # Feuille riz + Poisson
        "SYL-131",  # Légumes riz + Poulet
        "SYL-132",  # Légumes riz + Bœuf
        "SYL-133",  # Légumes riz + Mouton
        "SYL-134",  # Légumes riz + Poisson
    ]

    bind.execute(
        products_table.update()
        .where(products_table.c.sku.in_(duplicate_skus))
        .values(is_active=False)
    )

    # Également par précaution au cas où les SKUs varieraient : désactiver par nom
    duplicate_names = [
        "Dah riz + Poulet",
        "Dah riz + Bœuf",
        "Dah riz + Boeuf",
        "Dah riz + Mouton",
        "Dah riz + Poisson",
        "Kabato Dah + Bœuf",
        "Feuille riz + Poulet",
        "Feuille riz + Bœuf",
        "Feuille riz + Boeuf",
        "Feuille riz + Mouton",
        "Feuille riz + Poisson",
        "Légumes riz + Poulet",
        "Légumes riz + Bœuf",
        "Légumes riz + Boeuf",
        "Légumes riz + Mouton",
        "Légumes riz + Poisson",
    ]
    bind.execute(
        products_table.update()
        .where(products_table.c.name.in_(duplicate_names))
        .values(is_active=False)
    )

    # 2. Harmoniser les libellés et prix officiels des 12 plats officiels conservés
    # Note : short_name est limité à 20 caractères max pour l'impression ticket thermique
    official_updates = [
        # Sauce Feuille
        ("SYL-016", "Sauce Feuille + Bœuf", "Sauce Feuille+Bœuf", 3000),
        ("SYL-017", "Sauce Feuille + Poulet", "Sauce Feuille+Poulet", 3000),
        ("SYL-018", "Sauce Feuille + Poisson", "Sauce Feuille+Pois.", 3500),
        ("SYL-019", "Sauce Feuille + Mouton", "Sauce Feuille+Mouton", 4000),
        # Sauce Dah
        ("SYL-020", "Sauce Dah + Bœuf", "Sauce Dah + Bœuf", 3000),
        ("SYL-021", "Sauce Dah + Poulet", "Sauce Dah + Poulet", 3000),
        ("SYL-022", "Sauce Dah + Poisson", "Sauce Dah + Poisson", 3500),
        ("SYL-023", "Sauce Dah + Mouton", "Sauce Dah + Mouton", 4000),
        # Sauce Légume
        ("SYL-024", "Sauce Légume + Bœuf", "Sauce Légume+Bœuf", 3000),
        ("SYL-025", "Sauce Légume + Poulet", "Sauce Légume+Poulet", 3000),
        ("SYL-026", "Sauce Légume + Poisson", "Sauce Légume+Pois.", 3500),
        ("SYL-027", "Sauce Légume + Mouton", "Sauce Légume+Mouton", 4000),
    ]

    for sku, name, short_name, price in official_updates:
        bind.execute(
            products_table.update()
            .where(products_table.c.sku == sku)
            .values(
                name=name,
                short_name=short_name,
                price_xof=price,
                is_active=True,
            )
        )


def downgrade() -> None:
    bind = op.get_bind()

    products_table = sa.table(
        "products",
        sa.column("sku", sa.String),
        sa.column("is_active", sa.Boolean),
    )

    duplicate_skus = [
        "SYL-122", "SYL-123", "SYL-124", "SYL-125", "SYL-126",
        "SYL-127", "SYL-128", "SYL-129", "SYL-130", "SYL-131",
        "SYL-132", "SYL-133", "SYL-134",
    ]

    bind.execute(
        products_table.update()
        .where(products_table.c.sku.in_(duplicate_skus))
        .values(is_active=True)
    )
