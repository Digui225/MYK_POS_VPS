"""Ventes par serveur : chiffre d'affaires des additions réglées, rangé par serveur de la note.

Le serveur d'une note est celui qui l'a ouverte ou qui a fait le premier envoi depuis son
téléphone ; un ajout sur la note d'un collègue reste au serveur de la note. Les commandes prises
à la caisse, sans serveur, forment la ligne « Caisse » : la somme des lignes retombe ainsi sur le
chiffre d'affaires du jour. Une note réglée à 0 F n'est pas une vente : elle n'est pas comptée.
"""

from collections.abc import Iterable
from dataclasses import dataclass

CASH_DESK_LABEL = "Caisse"


@dataclass(frozen=True)
class ServerSalesLine:
    server_user_id: str | None
    server_name: str
    orders_count: int
    total_sales_ttc_xof: int
    average_basket_xof: int


def sales_by_server(
    sales: Iterable[tuple[str | None, str | None, int]],
) -> list[ServerSalesLine]:
    """`sales` : (id du serveur ou None, nom, montant TTC) pour chaque addition réglée.

    Du plus gros chiffre d'affaires au plus petit (à égalité, par nom)."""
    totals: dict[str | None, tuple[str, int, int]] = {}
    for user_id, name, amount in sales:
        if amount <= 0:
            continue
        label = ((name or "").strip() or CASH_DESK_LABEL) if user_id else CASH_DESK_LABEL
        _, count, total = totals.get(user_id, (label, 0, 0))
        totals[user_id] = (label, count + 1, total + amount)
    lines = [
        ServerSalesLine(
            server_user_id=user_id,
            server_name=label,
            orders_count=count,
            total_sales_ttc_xof=total,
            average_basket_xof=total // count,
        )
        for user_id, (label, count, total) in totals.items()
    ]
    return sorted(lines, key=lambda line: (-line.total_sales_ttc_xof, line.server_name))
