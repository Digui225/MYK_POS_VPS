"""fne_point_of_sale_setting

Revision ID: 018_fne_point_of_sale_setting
Revises: 017_link_poisson_to_carpe
Create Date: 2026-10-28 13:50:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "018_fne_point_of_sale_setting"
down_revision: Union[str, None] = "017_link_poisson_to_carpe"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    settings_table = sa.table(
        "settings",
        sa.column("key", sa.String),
        sa.column("value", sa.JSON),
    )

    for key, val in [
        ("fne.point_of_sale", "point de vente 1"),
        ("fne.establishment", "RESTAURANT CHEZ SYLLA PLUS"),
    ]:
        exists = bind.execute(
            sa.select(settings_table.c.key).where(settings_table.c.key == key)
        ).scalar_one_or_none()
        if exists:
            bind.execute(
                settings_table.update().where(settings_table.c.key == key).values(value=val)
            )
        else:
            bind.execute(
                settings_table.insert().values(key=key, value=val)
            )


def downgrade() -> None:
    pass
