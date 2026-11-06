"""Plan de salle : grille de placement des tables, règles pures (sans base de données).

Chaque zone (Salle, Terrasse…) a son propre plan, une grille de `GRID_COLUMNS` colonnes —
la largeur d'un téléphone — et d'autant de lignes que nécessaire. Une table occupe un
rectangle de cases (`plan_w` × `plan_h`) à partir de sa case haut-gauche (`plan_x`,
`plan_y`). Une table sans position n'est pas encore placée : les écrans la rangent
automatiquement en attendant.
"""

from collections.abc import Iterable
from dataclasses import dataclass

GRID_COLUMNS = 12
MAX_ROWS = 60
MAX_TABLE_SPAN = 6  # côté maximal d'une table, en cases
DEFAULT_TABLE_SPAN = 2


@dataclass(frozen=True)
class Placement:
    table_id: str
    label: str
    zone: str
    x: int
    y: int
    w: int
    h: int


def fits_grid(x: int, y: int, w: int, h: int) -> bool:
    """Vrai si le rectangle tient entièrement dans la grille."""
    return (
        0 <= x
        and 0 <= y
        and 1 <= w <= MAX_TABLE_SPAN
        and 1 <= h <= MAX_TABLE_SPAN
        and x + w <= GRID_COLUMNS
        and y + h <= MAX_ROWS
    )


def _intersects(a: Placement, b: Placement) -> bool:
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h


def find_overlaps(placements: Iterable[Placement]) -> list[tuple[Placement, Placement]]:
    """Paires de tables d'une même zone qui se chevauchent (ordre stable, par libellé)."""
    by_zone: dict[str, list[Placement]] = {}
    for p in placements:
        by_zone.setdefault(p.zone, []).append(p)
    overlaps: list[tuple[Placement, Placement]] = []
    for zone in sorted(by_zone):
        items = sorted(by_zone[zone], key=lambda p: (p.label, p.table_id))
        for i, a in enumerate(items):
            for b in items[i + 1 :]:
                if _intersects(a, b):
                    overlaps.append((a, b))
    return overlaps
