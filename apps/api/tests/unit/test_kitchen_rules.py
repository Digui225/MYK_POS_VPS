from datetime import datetime, timezone

from caisse.domain.kitchen_rules import (
    KitchenLine,
    KitchenTicket,
    format_kitchen_ticket_text,
    is_kitchen_line,
    kitchen_ticket_layout,
    line_columns,
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
        "lines": (KitchenLine(1, "Foufou boeuf", line_total_xof=3500),),
    }
    base.update(overrides)
    return KitchenTicket(**base)  # type: ignore[arg-type]


def _plain(ticket: KitchenTicket) -> str:
    return format_kitchen_ticket_text(ticket, escpos=False)


def test_drinks_stay_at_the_till() -> None:
    assert is_kitchen_line("FOOD") is True
    assert is_kitchen_line("OTHER") is True
    assert is_kitchen_line(None) is True  # hors menu sans catégorie : en cuisine par prudence
    assert is_kitchen_line("DRINK") is False


def test_every_line_fits_the_58mm_paper() -> None:
    long_line = KitchenLine(
        2,
        "Plat brochet braisé avec attiéké et alloco bien chaud",
        note="sauce à part, sans piment",
        seat=3,
        line_total_xof=125000,
    )
    for ticket in (
        _ticket(lines=(long_line,)),
        _ticket(table_label="Terrasse 12", note_label="Note 2", dispatch_no=3),  # lieu trop long : double hauteur
        _ticket(
            dispatch_no=2,
            already_sent=(KitchenLine(3, "Plat poulet braisé"), KitchenLine(1, "Attiéké poisson")) * 3,
            order_total_xof=1250000,
        ),
    ):
        # colonnes réelles : un caractère en double largeur en occupe deux
        assert all(line_columns(line) <= 32 for line in kitchen_ticket_layout(ticket))
    text = _plain(_ticket(lines=(long_line,)))
    assert "2 x PLAT BROCHET BRAISÉ" in text and "125 000" in text
    assert "    > convive 3" in text
    assert "    > sauce à part, sans piment" in text


def test_header_shows_place_waiter_time_and_dispatch() -> None:
    text = _plain(_ticket())
    assert "CUISINE" in text
    assert "TABLE 3 - NOTE 1" in text and "ENVOI 1" in text
    assert "Serveur : KOFFI" in text
    assert "4 couverts - 12:47" in text  # Abidjan = UTC
    assert "AJOUT" not in text and "Déjà envoyé" not in text


def test_each_dish_carries_its_price_and_the_dispatch_total() -> None:
    text = _plain(
        _ticket(lines=(KitchenLine(1, "Foufou boeuf", line_total_xof=3500), KitchenLine(2, "Plat poulet", line_total_xof=7000)))
    )
    lines = text.splitlines()
    assert any(line.startswith("1 x FOUFOU BOEUF") and line.endswith("3 500") for line in lines)
    assert any(line.startswith("2 x PLAT POULET") and line.endswith("7 000") for line in lines)
    assert any(line.startswith("TOTAL ENVOI") and line.endswith("10 500 F") for line in lines)
    assert "sans prix" not in text
    assert "Cde 2026-11-06-0012 - envoi 1" in text


def test_addition_recalls_what_was_already_sent() -> None:
    text = _plain(
        _ticket(
            dispatch_no=2,
            already_sent=(KitchenLine(1, "Plat brochet"), KitchenLine(1, "Plat poulet")),
            first_sent_at=datetime(2026, 11, 6, 12, 24, tzinfo=timezone.utc),
            order_total_xof=10500,
        )
    )
    assert "*** AJOUT ***" in text and "ENVOI 2" in text
    assert "Déjà envoyé (12:24) :" in text
    assert "1 Plat brochet, 1 Plat poulet" in text
    assert any(line.startswith("Total note") and line.endswith("10 500 F") for line in text.splitlines())


def test_takeaway_and_delivery_labels() -> None:
    takeaway = _plain(_ticket(service_mode="EMPORTER", table_label=None, note_label=None))
    delivery = _plain(_ticket(service_mode="LIVRAISON", table_label=None, note_label=None))
    assert "A EMPORTER" in takeaway and "couverts" not in takeaway
    assert "LIVRAISON" in delivery


def test_escpos_codes_are_printable_and_reset_after_each_styled_line() -> None:
    text = format_kitchen_ticket_text(_ticket())
    assert "\x00" not in text  # une colonne texte PostgreSQL refuse l'octet nul
    assert text.startswith("\x1dB\x01\x1b!8")  # bandeau blanc sur noir, double taille
    assert "\x1b!\x181 x FOUFOU BOEUF" in text  # plat en gras, double hauteur
    # le retour au texte normal suit toujours un saut de ligne : la ligne est déjà imprimée
    assert text.count("\x1b@") == text.count("\n\x1b@")
    assert format_kitchen_ticket_text(_ticket(), escpos=False) == _plain(_ticket())
