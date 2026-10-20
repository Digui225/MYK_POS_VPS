from caisse.domain import receipt


def test_render_receipt_contains_lines_total_and_payments() -> None:
    rendered = receipt.render_receipt(
        order_number="2026-10-05-0001",
        table_label="1",
        counter_number=None,
        items=[
            receipt.ReceiptLine(name="Poisson braisé", quantity=2, line_total_xof=7000),
            receipt.ReceiptLine(
                name="Attiéké", quantity=2, line_total_xof=2000, note="sans piment"
            ),
        ],
        payments=[
            receipt.ReceiptPayment(method="CASH", amount_xof=9000, change_xof=1000),
        ],
        total_ttc_xof=9000,
        header_name="RESTAURANT CHEZ SYLLA PLUS",
        header_address="Yopougon",
        header_phone="0102030405",
        footer="Merci de votre visite",
        width=48,
    )
    assert "2026-10-05-0001" in rendered
    assert "Table 1" in rendered
    assert "Poisson braisé" in rendered
    assert "(sans piment)" in rendered
    assert "9 000 XOF" in rendered
    assert "Espèces" in rendered
    assert "1 000 XOF" in rendered  # rendu monnaie
    assert "Merci de votre visite" in rendered
    assert all(len(line) <= 48 for line in rendered.splitlines())


def test_render_receipt_counter_sale_has_no_table() -> None:
    rendered = receipt.render_receipt(
        order_number="2026-10-05-0002",
        table_label=None,
        counter_number=7,
        items=[receipt.ReceiptLine(name="Jus de bissap", quantity=1, line_total_xof=1000)],
        payments=[receipt.ReceiptPayment(method="CARD", amount_xof=1000)],
        total_ttc_xof=1000,
        header_name="RESTAURANT CHEZ SYLLA PLUS",
        header_address=None,
        header_phone=None,
        footer="",
        width=48,
    )
    assert "Comptoir n° 7" in rendered
    assert "Table" not in rendered


def test_render_z_report_contains_totals_and_variance() -> None:
    rendered = receipt.render_z_report(
        z_number=3,
        business_date="2026-10-05",
        opening_float_xof=20000,
        gross_ttc_xof=50000,
        by_payment_method=[receipt.PaymentMethodAmount(method="CASH", amount_xof=50000)],
        expected_cash_xof=70000,
        counted_cash_xof=69500,
        variance_xof=-500,
        cancelled_orders=1,
        removed_items=2,
        header_name="RESTAURANT CHEZ SYLLA PLUS",
        footer="",
        width=48,
    )
    assert "RAPPORT Z n° 3" in rendered
    assert "50 000 XOF" in rendered
    assert "-500 XOF" in rendered
    assert "1 / 2" in rendered


def test_mobile_money_label_and_legal_mentions() -> None:
    assert receipt.payment_label("MOBILE_MONEY", "WAVE") == "Wave"
    assert receipt.payment_label("MOBILE_MONEY", "orange") == "Orange Money"
    assert receipt.payment_label("MOBILE_MONEY", None) == "Mobile Money"
    assert receipt.payment_label("CASH") == "Espèces"
    text = receipt.render_receipt(
        order_number="2026-10-16-0001",
        table_label=None,
        counter_number=1,
        items=[receipt.ReceiptLine(name="Alloco", quantity=1, line_total_xof=1000)],
        payments=[receipt.ReceiptPayment(method="MOBILE_MONEY", amount_xof=1000, provider="MTN")],
        total_ttc_xof=1000,
        header_name="RESTAURANT CHEZ SYLLA PLUS",
        header_address=None,
        header_phone=None,
        footer="",
        width=48,
        header_ncc="9506466A",
    )
    lines = text.splitlines()
    assert lines[1].strip() == "NCC 9506466A"
    assert any(line.startswith("MTN MoMo") and line.endswith("1 000 XOF") for line in lines)


def test_render_test_ticket_uses_width() -> None:
    rendered = receipt.render_test_ticket(printed_at="20/10/2026 16:00:00", width=32)
    lines = rendered.splitlines()
    assert lines[0] == "TICKET DE TEST".center(32)
    assert "-" * 32 in lines
    assert "Largeur    : 32 caractères" in lines
    assert "20/10/2026 16:00:00" in rendered


def test_render_receipt_wraps_on_58mm() -> None:
    """32 caractères (58 mm) : aucune ligne ne déborde, les mots ne sont jamais coupés."""
    rendered = receipt.render_receipt(
        order_number="2026-10-20-0012",
        table_label="7",
        counter_number=None,
        items=[
            receipt.ReceiptLine(
                name="Poisson braisé + attiéké garni", quantity=2, line_total_xof=7000
            )
        ],
        payments=[receipt.ReceiptPayment(method="CASH", amount_xof=7000)],
        total_ttc_xof=7000,
        header_name="RESTAURANT CHEZ SYLLA PLUS",
        header_address="Yopougon",
        header_phone=None,
        header_ncc="9502363N",
        header_rccm="CI-ABJ-2020-B-12345",
        footer="Merci de votre visite, à bientôt chez Sylla Plus",
        width=32,
    )
    lines = rendered.splitlines()
    assert max(len(line) for line in lines) <= 32
    assert "2 x Poisson braisé + attiéké" in lines
    assert "    garni" in lines
    assert "NCC 9502363N".center(32) in lines
    assert "RCCM CI-ABJ-2020-B-12345".center(32) in lines
