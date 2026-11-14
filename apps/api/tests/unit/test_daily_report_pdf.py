"""Rapport de ventes PDF produit par le serveur et message SMTP qui le transporte."""

from datetime import date, datetime, timezone

import pytest

from caisse.core.config import Settings
from caisse.infrastructure.mail import MailAttachment, MailNotConfiguredError, OutgoingMail
from caisse.infrastructure.mail.smtp import build_message, send_mail
from caisse.schemas.reports import (
    DashboardOut,
    SalesCategory,
    SalesProduct,
    SalesReportOut,
    SalesTotals,
)
from caisse.services.daily_report_pdf import (
    build_daily_report_pdf,
    format_day,
    format_xof,
    product_lines,
    status_text,
)

DAY = date(2026, 11, 12)


def _overview(**over: object) -> DashboardOut:
    data: dict[str, object] = {
        "business_date": DAY, "revenue_xof": 0, "orders_paid": 0, "orders_open": 0,
        "orders_cancelled": 0, "average_ticket_xof": 0, "guests_count": 0, "dine_in_orders": 0,
        "takeaway_orders": 0, "delivery_orders": 0, "tables_occupied": 0, "tables_total": 0,
        "payments": [], "top_products": [], "hourly": [], "by_cashier": [], "sessions": [],
        "low_stock_articles": 0, "fne": {"certified": 0, "pending": 0},
    }
    data.update(over)
    return DashboardOut.model_validate(data)


def _session(status: str, z: int | None) -> dict[str, object]:
    return {
        "id": f"s-{z}", "cash_register": "point de vente 1", "status": status, "opened_by": "Prisca",
        "opened_at": datetime(2026, 11, 12, 8, tzinfo=timezone.utc), "closed_at": None,
        "z_number": z, "variance_xof": 0,
    }


def _sales(products: list[tuple[str, str, int, int]]) -> SalesReportOut:
    """Seuls les champs lus par le rapport (produits, catégories, CA total)."""
    categories: dict[str, int] = {}
    for _, cat, _, rev in products:
        categories[cat] = categories.get(cat, 0) + rev
    return SalesReportOut.model_construct(
        totals=SalesTotals.model_construct(revenue_xof=sum(p[3] for p in products)),
        by_product=[
            SalesProduct.model_construct(name=name, category=cat, quantity=qty, revenue_xof=rev)
            for name, cat, qty, rev in products
        ],
        by_category=[
            SalesCategory.model_construct(category=c, revenue_xof=r)
            for c, r in sorted(categories.items(), key=lambda kv: -kv[1])
        ],
    )


def test_formats() -> None:
    assert format_xof(1475500) == "1 475 500 FCFA"
    assert format_xof(-19500) == "-19 500 FCFA"
    assert format_day(DAY) == "jeudi 12 novembre 2026"


def test_status_stamp_follows_the_sessions_of_the_day() -> None:
    assert status_text(_overview())[0] == "AUCUNE SESSION DE CAISSE"
    assert status_text(_overview(sessions=[_session("OPEN", None)]))[0] == "PROVISOIRE — CAISSE OUVERTE"
    closed = _overview(sessions=[_session("CLOSED", 3), _session("CLOSED", 2)])
    assert status_text(closed)[0] == "JOURNÉE CLÔTURÉE — Z N° 2, 3"


def test_products_grouped_by_category_by_revenue() -> None:
    sales = _sales([
        ("Jus de bissap", "Jus", 3, 1500),
        ("Sauce Dah + Bœuf", "Spécial Sauce", 2, 6000),
        ("Sauce Feuille + Poulet", "Spécial Sauce", 4, 12000),
    ])
    lines = [(line.kind, line.label, line.quantity, line.revenue_xof) for line in product_lines(sales)]
    assert lines == [
        ("category", "Spécial Sauce", 6, 18000),
        ("product", "Sauce Feuille + Poulet", 4, 12000),
        ("product", "Sauce Dah + Bœuf", 2, 6000),
        ("category", "Jus", 3, 1500),
        ("product", "Jus de bissap", 3, 1500),
    ]


def test_pdf_with_french_text_and_several_pages() -> None:
    empty = build_daily_report_pdf(DAY, _overview(), _sales([]))
    assert empty.startswith(b"%PDF") and empty.count(b"/Type /Page\n") == 1

    many = [(f"Plat n° {i} — Bœuf « maison »", f"Catégorie {i % 5}", 1, 1000 + i) for i in range(90)]
    pdf = build_daily_report_pdf(DAY, _overview(revenue_xof=99000), _sales(many))
    assert pdf.count(b"/Type /Page\n") >= 2


def _settings(**over: object) -> Settings:
    return Settings(SMTP_HOST="pro.turbo-smtp.com", SMTP_FROM="rapports@caisse.osispos.com", **over)  # type: ignore[arg-type]


def test_message_has_sender_subject_and_pdf() -> None:
    mail = OutgoingMail(
        to=["m.yapi@example.com", "patron@example.com"],
        subject="Rapport de ventes — jeudi 12 novembre 2026",
        text="Bonjour",
        attachments=[MailAttachment("Rapport_Ventes_2026-11-12.pdf", b"%PDF-1.4")],
    )
    msg = build_message(mail, _settings())
    assert msg["From"] == "Caisse MYK <rapports@caisse.osispos.com>"
    assert msg["To"] == "m.yapi@example.com, patron@example.com"
    assert msg["Subject"] == "Rapport de ventes — jeudi 12 novembre 2026"
    assert msg.get_body(preferencelist=("plain",)).get_content().strip() == "Bonjour"
    html = OutgoingMail(to=["a@b.co"], subject="x", text="Bonjour", html="<p>Bonjour</p>")
    html_msg = build_message(html, _settings())
    assert html_msg.get_body(preferencelist=("html",)).get_content().strip() == "<p>Bonjour</p>"
    [att] = list(msg.iter_attachments())
    assert att.get_filename() == "Rapport_Ventes_2026-11-12.pdf"
    assert att.get_content_type() == "application/pdf"
    assert att.get_content() == b"%PDF-1.4"


def test_send_refused_without_smtp() -> None:
    with pytest.raises(MailNotConfiguredError):
        send_mail(OutgoingMail(to=["a@b.co"], subject="x", text="y"), Settings(SMTP_HOST=""))
