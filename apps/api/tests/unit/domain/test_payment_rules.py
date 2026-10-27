import pytest
from caisse.domain.enums import PaymentMethod
from caisse.domain.payment_rules import (
    validate_payment_amount,
    calculate_change,
    should_open_drawer,
    build_esc_pos_bytes,
    format_receipt_text,
    ESC_DRAWER_KICK,
    ESC_CUT_PAPER,
)
from caisse.errors import CaisseException


def test_validate_payment_amount_valid():
    validate_payment_amount(5000, 10000)
    validate_payment_amount(10000, 10000)


def test_validate_payment_amount_invalid_negative_or_zero():
    with pytest.raises(CaisseException) as exc:
        validate_payment_amount(0, 5000)
    assert exc.value.code == "INVALID_PAYMENT_AMOUNT"

    with pytest.raises(CaisseException) as exc:
        validate_payment_amount(-1000, 5000)
    assert exc.value.code == "INVALID_PAYMENT_AMOUNT"


def test_validate_payment_amount_overpayment():
    with pytest.raises(CaisseException) as exc:
        validate_payment_amount(15000, 10000)
    assert exc.value.code == "OVERPAYMENT_NOT_ALLOWED"


def test_calculate_change_cash_valid():
    # Remis 10 000 pour 7 500 à payer = 2 500 de rendu
    change = calculate_change(tendered_xof=10000, amount_xof=7500, method=PaymentMethod.CASH)
    assert change == 2500

    # Remis exact
    change_exact = calculate_change(tendered_xof=5000, amount_xof=5000, method=PaymentMethod.CASH)
    assert change_exact == 0


def test_calculate_change_cash_insufficient():
    with pytest.raises(CaisseException) as exc:
        calculate_change(tendered_xof=4000, amount_xof=5000, method=PaymentMethod.CASH)
    assert exc.value.code == "INSUFFICIENT_TENDERED_AMOUNT"


def test_calculate_change_non_cash():
    change = calculate_change(tendered_xof=10000, amount_xof=5000, method=PaymentMethod.MOBILE_MONEY)
    assert change == 0


def test_should_open_drawer_rules():
    assert should_open_drawer(PaymentMethod.CASH) is True
    assert should_open_drawer(PaymentMethod.MOBILE_MONEY) is False
    assert should_open_drawer(PaymentMethod.CARD) is False

    # Duplicata : jamais d'ouverture de tiroir
    assert should_open_drawer(PaymentMethod.CASH, is_reprint=True) is False

    # Action manuelle responsable : ouverture forcée
    assert should_open_drawer(PaymentMethod.MOBILE_MONEY, is_manual_override=True) is True


def test_build_esc_pos_bytes():
    raw_cash = build_esc_pos_bytes("Test ticket", open_drawer=True, cut=True)
    assert ESC_DRAWER_KICK in raw_cash
    assert ESC_CUT_PAPER in raw_cash
    assert b"Test ticket" in raw_cash

    raw_momo = build_esc_pos_bytes("Test ticket momo", open_drawer=False, cut=True)
    assert ESC_DRAWER_KICK not in raw_momo
    assert ESC_CUT_PAPER in raw_momo


def test_format_receipt_text_rendering():
    text = format_receipt_text(
        restaurant_info={"name": "MYK TEST RESTO", "address": "Riviera", "phone": "07000000"},
        order_info={"order_number": "2026-09-28-0001", "table_label": "Table 1", "guests_count": 2, "cashier_name": "Awa", "date_str": "28/09/2026 12:00"},
        items=[
            {"name": "Poisson Braisé", "quantity": 1, "line_total_xof": 6000},
            {"name": "Attiéké", "quantity": 2, "line_total_xof": 1000},
        ],
        payments=[{"method": "CASH", "amount_xof": 7000}],
        totals={"total_ttc_xof": 7000, "total_vat_xof": 1068, "vat_rate": 18, "change_xof": 0},
        is_duplicate=False,
    )
    assert "MYK TEST RESTO" in text
    assert "2026-09-28-0001" in text
    assert "Poisson Braisé" in text
    assert "7 000 F" in text
    assert "DUPLICATA" not in text

    dup_text = format_receipt_text(
        restaurant_info={"name": "MYK TEST RESTO"},
        order_info={"order_number": "2026-09-28-0001"},
        items=[],
        payments=[],
        totals={"total_ttc_xof": 0, "total_vat_xof": 0},
        is_duplicate=True,
    )
    assert "DUPLICATA" in dup_text


def test_format_receipt_text_mobile_money_personalized_labels():
    text = format_receipt_text(
        restaurant_info={"name": "MYK TEST RESTO"},
        order_info={"order_number": "2026-10-13-0001"},
        items=[{"name": "Bissap", "quantity": 1, "line_total_xof": 2000}],
        payments=[
            {"method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 1000},
            {"method": "MOBILE_MONEY", "provider": "ORANGE_MONEY", "amount_xof": 1000},
        ],
        totals={"total_ttc_xof": 2000, "total_vat_xof": 0},
    )
    assert "Paiement Wave :" in text
    assert "Paiement Orange Money :" in text


def test_sanitize_french_text_removes_accents_and_special_chars():
    from caisse.domain.payment_rules import sanitize_french_text
    sample = "Désignation · Poulet Braisé DG · Tél : +225 · TOTAL RÉGLÉ · À très bientôt !"
    cleaned = sanitize_french_text(sample)
    assert "Designation" in cleaned
    assert "Braise" in cleaned
    assert "Tel :" in cleaned
    assert "TOTAL REGLE" in cleaned
    assert "A tres bientot !" in cleaned
    # Ensure pure 7-bit ASCII
    cleaned.encode("ascii")


def test_esc_pos_contains_chinese_cancellation_and_qr():
    from caisse.domain.payment_rules import FS_CANCEL_CHINESE, build_esc_pos_qr
    raw = build_esc_pos_bytes("Test accents: Théâtre", open_drawer=False, cut=True, qr_data="https://dgi.ci/test")
    assert FS_CANCEL_CHINESE in raw
    assert b"Theatre" in raw
    assert b"\xc3\xa9" not in raw  # No UTF-8 é that causes Chinese ideograms!
    
    # Test QR code generator
    qr_bytes = build_esc_pos_qr("https://dgi.ci/fne/123", size=4)
    assert b"\x1d\x28\x6b" in qr_bytes


def test_format_z_report_text():
    from caisse.domain.payment_rules import format_z_report_text
    z_data = {
        "z_number": 3,
        "business_date": "2026-10-05",
        "opened_at": "2026-10-05T09:00:00",
        "closed_at": "2026-10-05T16:23:00",
        "opening_float_xof": 50000,
        "total_sales_ttc_xof": 93300,
        "total_sales_ht_xof": 93300,
        "total_sales_vat_xof": 0,
        "payments_by_method": {"CASH": 93300},
        "sales_by_category": {"Viandes": 31500, "Poissons": 52500},
        "cash_movements_in_xof": 0,
        "cash_movements_out_xof": 0,
        "expected_cash_in_drawer_xof": 143300,
        "counted_cash_xof": 143300,
        "variance_xof": 0,
        "orders_count": 5,
        "cancelled_orders_count": 0,
    }
    txt = format_z_report_text({"name": "SYLLA PLUS"}, z_data, width=32)
    assert "RAPPORT Z N* 3" in txt
    assert "CLOTURE DEFINITIVE" in txt
    assert "TOTAL VENTES TTC" in txt
    assert "93 300 F" in txt
    assert "ECART DE CAISSE" in txt
    assert "[LOGO]" not in txt


def test_format_receipt_text_long_items_and_clean_layout():
    text = format_receipt_text(
        restaurant_info={
            "name": "Sylla Plus",
            "address": "Abidjan Plateau",
            "phone": "0748735573",
            "ncc": "1304777N",
            "rccm": "CI-ABJ-2023-B-00000",
            "footer": "Merci de votre visite et a tres bientot !",
        },
        order_info={
            "order_number": "2026-10-27-0001",
            "cashier_name": "Prisca",
            "table_label": "T1",
            "date_str": "27/10/26 11:45",
        },
        items=[
            {"name": "Sauce Claire + Bœuf", "quantity": 1, "line_total_xof": 3500},
            {"name": "Foutou djougble + Bœuf", "quantity": 1, "line_total_xof": 3500},
            {"name": "Coca", "quantity": 1, "line_total_xof": 1000},
        ],
        payments=[{"method": "CASH", "amount_xof": 8000}],
        totals={"total_ttc_xof": 8000, "total_vat_xof": 0},
    )

    # 1. Pas de [LOGO] en texte brut
    assert "[LOGO]" not in text

    # 2. Correction de la ligature œ en oe
    assert "Bœuf" not in text
    assert "Boeuf" in text

    # 3. Wrapping propre des articles longs (la protéine + le prix sont sur la même 2e ligne)
    assert "1x Sauce Claire +" in text
    assert "  Boeuf               3 500 FCFA" in text
    assert "1x Foutou djougble +" in text

    # 4. Article court sur une seule ligne
    assert "1x Coca               1 000 FCFA" in text

    # 5. Pied de ticket équilibré
    assert "Merci de votre visite" in text
    assert "et a tres bientot !" in text
    assert "visite et a tres\n" not in text



