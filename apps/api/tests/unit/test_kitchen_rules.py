from datetime import datetime, timezone

from caisse.domain.kitchen_rules import (
    KitchenLine,
    KitchenTicket,
    format_kitchen_ticket_text,
    is_kitchen_line,
)


def _ticket(**overrides: object) -> KitchenTicket:
    base: dict[str, object] = {
        "order_number": "2026-11-06-0012",
        "service_mode": "SUR_PLACE",
        "table_label": "Table 3",
        "note_label": "Note 1",
        "server_name": "Koffi",
        "guests_count": 4,
        "dispatch_no": 1,
        "sent_at": datetime(2026, 11, 6, 12, 47, tzinfo=timezone.utc),
        "lines": (KitchenLine(1, "Foufou boeuf"),),
    }
    base.update(overrides)
    return KitchenTicket(**base)  # type: ignore[arg-type]


def test_drinks_stay_at_the_till() -> None:
    assert is_kitchen_line("FOOD") is True
    assert is_kitchen_line("OTHER") is True
    assert is_kitchen_line(None) is True  # hors menu sans catégorie : en cuisine par prudence
    assert is_kitchen_line("DRINK") is False


def test_every_line_fits_the_58mm_paper() -> None:
    text = format_kitchen_ticket_text(
        _ticket(
            lines=(
                KitchenLine(2, "Plat brochet braisé avec attiéké et alloco bien chaud", note="sauce à part, sans piment", seat=3),
            ),
        )
    )
    assert all(len(line) <= 32 for line in text.splitlines())
    assert "2 x PLAT BROCHET BRAISÉ AVEC" in text
    assert "    > convive 3" in text
    assert "    > sauce à part, sans piment" in text


def test_header_shows_place_waiter_time_and_dispatch() -> None:
    text = format_kitchen_ticket_text(_ticket())
    assert "TABLE 3 - NOTE 1" in text and "ENVOI 1" in text
    assert "Serveur : KOFFI" in text
    assert "4 couverts" in text and "12:47" in text  # Abidjan = UTC
    assert "AJOUT" not in text


def test_addition_and_takeaway_labels() -> None:
    assert "*** AJOUT ***" in format_kitchen_ticket_text(_ticket(dispatch_no=2))
    takeaway = format_kitchen_ticket_text(_ticket(service_mode="EMPORTER", table_label=None, note_label=None))
    delivery = format_kitchen_ticket_text(_ticket(service_mode="LIVRAISON", table_label=None, note_label=None))
    assert "A EMPORTER" in takeaway and "couverts" not in takeaway
    assert "LIVRAISON" in delivery
