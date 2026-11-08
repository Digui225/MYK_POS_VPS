"""masquer_anciens_menus

Retire de la carte (caisse et téléphones de salle) quatre menus qui n'y sont plus :
« Viandes », « Poissons », « Spécial Jus » et « Spécial Desserts » (demande du 07/11/2026).

- « Salade de fruits », qui n'existait que dans « Spécial Desserts », passe dans
  « Boissons chaudes et desserts » et reste en vente ;
- les quatre catégories et leurs produits sont **masqués** (`is_active = false`), jamais
  supprimés : des tickets, rapports et la matrice des protéines y renvoient (rien ne s'efface
  après encaissement). Le stock n'est pas touché.

Correspondance par nom : si un nom diffère en production, la ligne concernée ne bouge pas.

Revision ID: 031_masquer_anciens_menus
Revises: 030_mode_de_service
Create Date: 2026-11-07 23:30:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

revision: str = "031_masquer_anciens_menus"
down_revision: Union[str, None] = "030_mode_de_service"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

HIDDEN_CATEGORIES = ["Viandes", "Poissons", "Spécial Jus", "Spécial Desserts"]
MOVED_PRODUCT = "Salade de fruits"
MOVED_FROM = "Spécial Desserts"
MOVED_TO = "Boissons chaudes et desserts"

categories = sa.table(
    "categories",
    sa.column("id", sa.String),
    sa.column("name", sa.String),
    sa.column("is_active", sa.Boolean),
)
products = sa.table(
    "products",
    sa.column("id", sa.String),
    sa.column("name", sa.String),
    sa.column("category_id", sa.String),
    sa.column("is_active", sa.Boolean),
)


def _category_id(bind: sa.engine.Connection, name: str) -> str | None:
    return bind.execute(sa.select(categories.c.id).where(categories.c.name == name)).scalar()


def _move(bind: sa.engine.Connection, source: str, target: str) -> None:
    source_id = _category_id(bind, source)
    target_id = _category_id(bind, target)
    if source_id and target_id:
        bind.execute(
            products.update()
            .where(products.c.name == MOVED_PRODUCT, products.c.category_id == source_id)
            .values(category_id=target_id)
        )


def _set_menus_active(bind: sa.engine.Connection, active: bool) -> None:
    ids = sa.select(categories.c.id).where(categories.c.name.in_(HIDDEN_CATEGORIES))
    bind.execute(products.update().where(products.c.category_id.in_(ids)).values(is_active=active))
    bind.execute(categories.update().where(categories.c.name.in_(HIDDEN_CATEGORIES)).values(is_active=active))


def upgrade() -> None:
    bind = op.get_bind()
    # 1. La salade de fruits reste en vente, avec les desserts de la carte
    _move(bind, MOVED_FROM, MOVED_TO)
    # 2. Les quatre menus et ce qu'ils contiennent encore disparaissent de la carte
    _set_menus_active(bind, False)


def downgrade() -> None:
    bind = op.get_bind()
    _set_menus_active(bind, True)
    _move(bind, MOVED_TO, MOVED_FROM)
