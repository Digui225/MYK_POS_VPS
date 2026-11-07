"""Séparer l'addition par convive : quelle ligne part sur quelle note (règle pure).

Deux clients qui ne sont pas ensemble paient séparément : chaque convive (siège 1..n) reçoit
sa propre note, donc son ticket et sa FNE. Les articles « pour la table » (siège 0 ou sans
siège) restent avec le premier convive, sur la note d'origine. Il faut au moins deux convives.
"""

from collections.abc import Iterable
from typing import Protocol


class _Line(Protocol):
    @property
    def seat(self) -> int | None: ...

    @property
    def removed_at(self) -> object | None: ...


def split_by_seat[L: _Line](lines: Iterable[L]) -> tuple[list[L], dict[int, list[L]]]:
    """(lignes qui restent sur la note d'origine, {convive: lignes qui partent sur sa note}).

    Les lignes retirées restent sur la note d'origine (elles y sont tracées). Lève
    `ValueError` s'il y a moins de deux convives.
    """
    active = [line for line in lines if line.removed_at is None]
    seats = sorted({line.seat for line in active if line.seat and line.seat > 0})
    if len(seats) < 2:
        raise ValueError("Il faut au moins deux convives pour séparer l'addition.")
    # Le premier convive garde la note d'origine, avec les articles pour la table
    moving: dict[int, list[L]] = {seat: [] for seat in seats[1:]}
    staying: list[L] = []
    for line in lines:
        if line.removed_at is None and line.seat in moving:
            moving[line.seat].append(line)
        else:
            staying.append(line)
    return staying, moving
