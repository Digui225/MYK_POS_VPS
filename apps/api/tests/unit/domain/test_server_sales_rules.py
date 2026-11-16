"""Ventes par serveur : regroupement par serveur de la note, ligne « Caisse », somme = CA."""

from caisse.domain.server_sales_rules import CASH_DESK_LABEL, sales_by_server


def test_groups_by_waiter_with_a_cash_desk_line() -> None:
    lines = sales_by_server(
        [
            ("u-koffi", "Koffi", 4000),
            (None, None, 3500),
            ("u-koffi", "Koffi", 3500),
            ("u-awa", "Awa", 3500),
        ]
    )
    assert [(x.server_name, x.orders_count, x.total_sales_ttc_xof, x.average_basket_xof) for x in lines] == [
        ("Koffi", 2, 7500, 3750),
        ("Awa", 1, 3500, 3500),  # à égalité avec la caisse : par nom
        (CASH_DESK_LABEL, 1, 3500, 3500),
    ]
    assert lines[2].server_user_id is None
    assert sum(x.total_sales_ttc_xof for x in lines) == 14500


def test_zero_notes_are_not_sales() -> None:
    assert sales_by_server([("u-koffi", "Koffi", 0), (None, None, 0)]) == []


def test_waiter_without_a_name_keeps_his_own_line() -> None:
    [line] = sales_by_server([("u-x", "  ", 2000)])
    assert line.server_user_id == "u-x"
    assert line.server_name == CASH_DESK_LABEL
