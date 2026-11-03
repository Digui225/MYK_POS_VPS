"""rename_bro_and_faux_bro_menu_products

Revision ID: 023_rename_bro_products
Revises: 022_add_condiments_envelope
Create Date: 2026-11-03 12:15:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "023_rename_bro_products"
down_revision: Union[str, None] = "022_add_condiments_envelope"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    dialect = bind.dialect.name

    if dialect == "postgresql":
        # 1. Remplacer 'faux brochet', 'faux bro', '+bro', '-bro' dans les noms de produits
        bind.execute(
            sa.text(
                r"""
                UPDATE products
                SET name = REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(name, '(?i)\yfaux[\s-]?brochet\y', 'Brochet', 'g'),
                            '(?i)\yfaux[\s-]?bro\y', 'Brochet', 'g'
                        ),
                        '\+([ \t]*)bro\y', '+\1Brochet', 'gi'
                    ),
                    '\-([ \t]*)bro\y', '-\1Brochet', 'gi'
                )
                WHERE name ~* '\yfaux[\s-]?brochet\y'
                   OR name ~* '\yfaux[\s-]?bro\y'
                   OR name ~* '\+([ \t]*)bro\y'
                   OR name ~* '\-([ \t]*)bro\y';
                """
            )
        )

        # 2. Mise à jour des noms courts (short_name, max 20 caractères)
        bind.execute(
            sa.text(
                r"""
                UPDATE products
                SET short_name = LEFT(
                    CASE
                        WHEN LENGTH(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        REGEXP_REPLACE(short_name, '(?i)\yfaux[\s-]?brochet\y', 'Brochet', 'g'),
                                        '(?i)\yfaux[\s-]?bro\y', 'Brochet', 'g'
                                    ),
                                    '\+([ \t]*)bro\y', '+\1Brochet', 'gi'
                                ),
                                '\-([ \t]*)bro\y', '-\1Brochet', 'gi'
                            )
                        ) > 20 THEN
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        REGEXP_REPLACE(
                                            REGEXP_REPLACE(short_name, '(?i)\ySauce\y', 'Sce', 'g'),
                                            '(?i)\yfaux[\s-]?brochet\y', 'Brochet', 'g'
                                        ),
                                        '(?i)\yfaux[\s-]?bro\y', 'Brochet', 'g'
                                    ),
                                    '\+([ \t]*)bro\y', '+\1Brochet', 'gi'
                                ),
                                '\-([ \t]*)bro\y', '-\1Brochet', 'gi'
                            )
                        ELSE
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    REGEXP_REPLACE(
                                        REGEXP_REPLACE(short_name, '(?i)\yfaux[\s-]?brochet\y', 'Brochet', 'g'),
                                        '(?i)\yfaux[\s-]?bro\y', 'Brochet', 'g'
                                    ),
                                    '\+([ \t]*)bro\y', '+\1Brochet', 'gi'
                                ),
                                '\-([ \t]*)bro\y', '-\1Brochet', 'gi'
                            )
                    END,
                    20
                )
                WHERE short_name ~* '\yfaux[\s-]?brochet\y'
                   OR short_name ~* '\yfaux[\s-]?bro\y'
                   OR short_name ~* '\+([ \t]*)bro\y'
                   OR short_name ~* '\-([ \t]*)bro\y';
                """
            )
        )

        # 3. Sécurité supplémentaire : articles de stock
        bind.execute(
            sa.text(
                r"""
                UPDATE stock_articles
                SET name = 'Brochet'
                WHERE (name ~* '\yfaux[\s-]?brochet\y' OR name ~* '\yfaux[\s-]?bro\y')
                  AND category = 'PROTEINE';
                """
            )
        )
    else:
        # SQLite / repli générique
        bind.execute(
            sa.text(
                """
                UPDATE products
                SET name = REPLACE(REPLACE(name, 'Faux bro', 'Brochet'), 'faux bro', 'brochet')
                WHERE name LIKE '%faux bro%' OR name LIKE '%Faux bro%';
                """
            )
        )
        bind.execute(
            sa.text(
                """
                UPDATE products
                SET name = REPLACE(REPLACE(name, '+bro', '+Brochet'), '+ bro', '+ Brochet')
                WHERE name LIKE '%+bro%' OR name LIKE '%+ bro%';
                """
            )
        )
        bind.execute(
            sa.text(
                """
                UPDATE products
                SET short_name = SUBSTR(REPLACE(REPLACE(short_name, 'Faux bro', 'Brochet'), 'Sauce ', 'Sce '), 1, 20)
                WHERE short_name LIKE '%faux bro%' OR short_name LIKE '%Faux bro%';
                """
            )
        )


def downgrade() -> None:
    pass

