"""Tableaux de bord et rapports : ventes et stock sur une période.

Lecture seule. Le coût matière vient des mouvements de vente (fiches techniques, au coût
moyen du moment de la vente) ; la consommation des articles suivis par inventaire et les
écarts viennent des inventaires et des pertes de la période.
"""

from collections import defaultdict
from datetime import date, datetime, timezone
from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Optional

from sqlalchemy import func
from sqlalchemy.orm import Session

from caisse.domain import stock_rules
from caisse.domain.enums import StockMovementType, StockOutMode
from caisse.errors import ValidationError
from caisse.models.cash_session import CashSession
from caisse.models.fne import FneDocument
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.models.stock import StockArticle
from caisse.models.table import RestaurantTable
from caisse.models.user import User
from caisse.repositories import fne as fne_repo
from caisse.repositories import reports as reports_repo
from caisse.repositories import stock as stock_repo
from caisse.schemas.report import (
    CashierSalesResponse,
    ClosingStatusResponse,
    DashboardKpiResponse,
    HourlySalesItem,
    PaymentMethodSplit,
    TopProductReport,
)
from caisse.schemas.reports import (
    DashboardCashier,
    DashboardFne,
    DashboardHour,
    DashboardOut,
    DashboardPayment,
    DashboardProduct,
    DashboardSession,
    SalesCashSession,
    SalesCategory,
    SalesDay,
    SalesPaymentMethod,
    SalesProduct,
    SalesReportOut,
    SalesTotals,
    StockReportArticle,
    StockReportOut,
    StockTotals,
)

MAX_DAYS = 366
_ZERO = Decimal(0)


def _xof(value: Decimal) -> int:
    return int(value.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def check_period(date_from: date, date_to: date) -> None:
    if date_from > date_to:
        raise ValidationError(
            "La date de début est postérieure à la date de fin.",
            meta={"date_from": str(date_from), "date_to": str(date_to)},
        )
    if (date_to - date_from).days >= MAX_DAYS:
        raise ValidationError(f"Période limitée à {MAX_DAYS} jours.", meta={"max_days": MAX_DAYS})


def sales_report(db: Session, date_from: date, date_to: date) -> SalesReportOut:
    check_period(date_from, date_to)
    days = reports_repo.sales_by_day(db, date_from, date_to)
    cost_by_day = reports_repo.recipe_cost_by_day(db, date_from, date_to)
    products = reports_repo.sales_by_product(db, date_from, date_to)
    cost_by_product = reports_repo.recipe_cost_by_product(db, date_from, date_to)
    recipes = stock_repo.components_by_product(db, [pid for pid, *_ in products])
    non_sale = reports_repo.non_sale_out_by_mode(db, date_from, date_to)

    by_product: list[SalesProduct] = []
    categories: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])  # qté, CA, coût
    for pid, name, category, quantity, revenue in products:
        cost = _xof(cost_by_product.get(pid, _ZERO))
        by_product.append(
            SalesProduct(
                product_id=str(pid),
                name=name,
                category=category or "Autre",
                quantity=quantity,
                revenue_xof=revenue,
                has_recipe=pid in recipes,
                recipe_cost_xof=cost,
                recipe_margin_xof=revenue - cost,
            )
        )
        cat_key = category or "Autre"
        bucket = categories[cat_key]
        bucket[0] += quantity
        bucket[1] += revenue
        bucket[2] += cost
    by_product.sort(key=lambda p: (-p.revenue_xof, p.name))

    revenue = sum(total for _, _, total in days)
    orders = sum(n for _, n, _ in days)
    recipe_cost = sum(p.recipe_cost_xof for p in by_product)
    consumption = _xof(non_sale.get(StockOutMode.INVENTORY, _ZERO))
    variance = _xof(non_sale.get(StockOutMode.RECIPE, _ZERO))
    totals = SalesTotals(
        revenue_xof=revenue,
        orders_count=orders,
        average_ticket_xof=round(revenue / orders) if orders else 0,
        recipe_cost_xof=recipe_cost,
        recipe_margin_xof=revenue - recipe_cost,
        uncosted_revenue_xof=sum(p.revenue_xof for p in by_product if not p.has_recipe),
        inventory_consumption_xof=consumption,
        stock_variance_xof=variance,
        gross_margin_xof=revenue - recipe_cost - consumption - variance,
    )
    return SalesReportOut(
        date_from=date_from,
        date_to=date_to,
        totals=totals,
        by_day=[
            SalesDay(
                business_date=d,
                orders_count=n,
                revenue_xof=total,
                recipe_cost_xof=_xof(cost_by_day.get(d, _ZERO)),
                recipe_margin_xof=total - _xof(cost_by_day.get(d, _ZERO)),
            )
            for d, n, total in days
        ],
        by_product=by_product,
        by_category=sorted(
            (
                SalesCategory(
                    category=name,
                    quantity=q,
                    revenue_xof=r,
                    recipe_cost_xof=c,
                    recipe_margin_xof=r - c,
                )
                for name, (q, r, c) in categories.items()
            ),
            key=lambda c: (-c.revenue_xof, c.category),
        ),
        by_payment_method=[
            SalesPaymentMethod(method=method, count=n, amount_xof=amount)
            for method, n, amount in reports_repo.payments_by_method(db, date_from, date_to)
        ],
        cash_sessions=[
            SalesCashSession(
                id=str(s.id),
                business_date=s.business_date,
                status=s.status,
                z_number=s.z_number,
                expected_cash_xof=s.expected_cash_xof,
                counted_cash_xof=s.counted_cash_xof,
                variance_xof=s.variance_xof,
            )
            for s in reports_repo.cash_sessions(db, date_from, date_to)
        ],
    )


def stock_report(db: Session, date_from: date, date_to: date) -> StockReportOut:
    check_period(date_from, date_to)
    period = reports_repo.movements_by_article_type(db, date_from, date_to)
    after = reports_repo.quantity_after(db, date_to)
    counts = reports_repo.last_count_dates(db, date_to)
    moved: set[str] = {aid for aid, _ in period}
    articles = [
        a for a in stock_repo.list_articles(db, is_active=None) if a.is_active or a.id in moved
    ]

    def qty(aid: str, *types: StockMovementType) -> Decimal:
        return sum((period.get((aid, t), (_ZERO, _ZERO))[0] for t in types), _ZERO)

    def value(aid: str, *types: StockMovementType) -> Decimal:
        return sum((period.get((aid, t), (_ZERO, _ZERO))[1] for t in types), _ZERO)

    sale_types = (StockMovementType.SALE_OUT, StockMovementType.RETURN_IN)
    count_types = (StockMovementType.INVENTORY_COUNT, StockMovementType.ADJUSTMENT)
    out_types = (*sale_types, StockMovementType.LOSS_OUT, *count_types)

    rows: list[StockReportArticle] = []
    totals: defaultdict[str, Decimal] = defaultdict(lambda: _ZERO)
    for a in articles:
        closing = a.quantity - after.get(a.id, _ZERO)
        # le stock de départ saisi pendant la période compte dans le début de période
        in_period = sum(
            (
                q
                for (aid, t), (q, _) in period.items()
                if aid == a.id and t != StockMovementType.OPENING
            ),
            _ZERO,
        )
        opening = closing - in_period
        purchased = qty(a.id, StockMovementType.PURCHASE_IN)
        purchases = value(a.id, StockMovementType.PURCHASE_IN)
        consumption_value = -value(a.id, *out_types)
        current_value = stock_rules.value_xof(max(a.quantity, _ZERO), a.avg_cost_xof)
        is_low = stock_rules.is_below_threshold(a.quantity, a.alert_threshold)
        non_sale = -value(a.id, StockMovementType.LOSS_OUT, *count_types)

        totals["stock_value"] += current_value
        totals["purchases"] += purchases
        totals["sales_cost"] += -value(a.id, *sale_types)
        totals["consumption" if a.out_mode == StockOutMode.INVENTORY else "variance"] += non_sale
        totals["low"] += 1 if is_low and a.is_active else 0
        rows.append(
            StockReportArticle(
                article_id=str(a.id),
                name=a.name,
                category=a.category,
                unit=a.unit,
                out_mode=a.out_mode,
                opening_quantity=float(opening),
                purchased_quantity=float(purchased),
                purchases_xof=_xof(purchases),
                sold_quantity=float(-qty(a.id, *sale_types)),
                loss_quantity=float(-qty(a.id, StockMovementType.LOSS_OUT)),
                count_adjustment_quantity=float(qty(a.id, *count_types)),
                closing_quantity=float(closing),
                consumption_quantity=float(opening + purchased - closing),
                consumption_xof=_xof(consumption_value),
                quantity=float(a.quantity),
                avg_cost_xof=float(a.avg_cost_xof),
                value_xof=current_value,
                alert_threshold=float(a.alert_threshold) if a.alert_threshold is not None else None,
                is_low=is_low,
                last_count_date=counts.get(a.id),
            )
        )
    return StockReportOut(
        date_from=date_from,
        date_to=date_to,
        totals=StockTotals(
            stock_value_xof=_xof(totals["stock_value"]),
            purchases_xof=_xof(totals["purchases"]),
            sales_cost_xof=_xof(totals["sales_cost"]),
            inventory_consumption_xof=_xof(totals["consumption"]),
            stock_variance_xof=_xof(totals["variance"]),
            low_count=int(totals["low"]),
        ),
        articles=rows,
    )


def dashboard(db: Session, day: date) -> DashboardOut:
    """Tableau de bord de la journée (responsable) : activité, tables, encaissements,
    meilleures ventes, heures, caissiers, sessions, alertes de stock, FNE."""
    paid, revenue, guests, dine_in, takeaway, open_orders, cancelled = reports_repo.day_orders(
        db, day
    )
    occupied, tables_total = reports_repo.tables_occupancy(db)
    top = sorted(reports_repo.sales_by_product(db, day, day), key=lambda r: (-r[4], r[1]))[:10]
    low = sum(
        1
        for a in stock_repo.list_articles(db)
        if stock_rules.is_below_threshold(a.quantity, a.alert_threshold)
    )
    certified, _ = fne_repo.certified_orders_totals(db, day)
    return DashboardOut(
        business_date=day,
        revenue_xof=revenue,
        orders_paid=paid,
        orders_open=open_orders,
        orders_cancelled=cancelled,
        average_ticket_xof=round(revenue / paid) if paid else 0,
        guests_count=guests,
        dine_in_orders=dine_in,
        takeaway_orders=takeaway,
        tables_occupied=occupied,
        tables_total=tables_total,
        payments=[
            DashboardPayment(method=m, provider=p, count=n, amount_xof=amount)
            for m, p, n, amount in reports_repo.payments_by_method_provider(db, day)
        ],
        top_products=[
            DashboardProduct(product_id=str(pid), name=name, quantity=qty, revenue_xof=total)
            for pid, name, _, qty, total in top
        ],
        hourly=[
            DashboardHour(hour=h, orders_count=n, revenue_xof=total)
            for h, n, total in reports_repo.sales_by_hour(db, day)
        ],
        by_cashier=[
            DashboardCashier(user_id=str(uid), full_name=name, orders_count=n, revenue_xof=total)
            for uid, name, n, total in reports_repo.sales_by_closer(db, day)
        ],
        sessions=[
            DashboardSession(
                id=str(s.id),
                cash_register=register,
                status=s.status,
                opened_by=opener,
                opened_at=s.opened_at,
                closed_at=s.closed_at,
                z_number=s.z_number,
                variance_xof=s.variance_xof,
            )
            for s, register, opener in reports_repo.day_sessions(db, day)
        ],
        low_stock_articles=low,
        fne=DashboardFne(certified=certified, pending=fne_repo.pending_for_date(db, day)),
    )


class ReportingService:
    def __init__(self, db: Session):
        self.db = db

    def get_dashboard_kpis(self, business_date_str: Optional[str] = None) -> DashboardKpiResponse:
        """Calcule les indicateurs clés de performance (KPIs) pour le tableau de bord direction."""
        if not business_date_str:
            business_date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        all_orders = self.db.query(Order).all()

        daily_orders = []
        for o in all_orders:
            match = False
            if o.created_at and o.created_at.strftime("%Y-%m-%d") == business_date_str:
                match = True
            elif o.cash_session and str(o.cash_session.business_date) == business_date_str:
                match = True
            if match:
                daily_orders.append(o)

        total_orders = len(daily_orders)
        settled_orders_list = [o for o in daily_orders if o.status == "PAID" or o.due_xof == 0]
        settled_orders = len(settled_orders_list)

        open_orders_list = [o for o in daily_orders if o.status in ("OPEN", "PARTIALLY_PAID")]
        open_orders = len(open_orders_list)

        active_tables_set = {o.table_id for o in open_orders_list if o.table_id is not None}
        active_tables_count = len(active_tables_set)

        total_tables_count = (
            self.db.query(func.count(RestaurantTable.id))
            .filter(RestaurantTable.is_active == True)
            .scalar()
            or 14
        )

        open_dine_in_count = sum(1 for o in open_orders_list if o.table_id is not None)
        open_takeaway_count = sum(1 for o in open_orders_list if o.table_id is None)

        dine_in_orders_count = open_dine_in_count if open_orders > 0 else sum(1 for o in daily_orders if o.table_id is not None and o.status != "CANCELLED")
        takeaway_orders_count = open_takeaway_count if open_orders > 0 else sum(1 for o in daily_orders if o.table_id is None and o.status != "CANCELLED")

        total_sales_ttc = sum(o.total_ttc_xof for o in settled_orders_list)
        total_sales_ht = sum(o.total_ht_xof for o in settled_orders_list)
        total_sales_vat = sum(o.total_vat_xof for o in settled_orders_list)
        avg_basket = (total_sales_ttc // settled_orders) if settled_orders > 0 else 0

        # Ventes horaires réelles
        hourly_map: dict[str, dict[str, int]] = {}
        for o in settled_orders_list:
            dt = o.paid_at or o.opened_at or o.created_at
            if dt:
                h_str = dt.strftime("%H") + "h"
                if h_str not in hourly_map:
                    hourly_map[h_str] = {"total_sales_xof": 0, "orders_count": 0}
                hourly_map[h_str]["total_sales_xof"] += o.total_ttc_xof
                hourly_map[h_str]["orders_count"] += 1

        hourly_sales = [
            HourlySalesItem(
                hour=h,
                total_sales_xof=data["total_sales_xof"],
                orders_count=data["orders_count"],
            )
            for h, data in sorted(hourly_map.items())
        ]

        # 2. Ventilation des paiements
        all_payments = self.db.query(Payment).all()
        settled_order_ids_set = {o.id for o in settled_orders_list}
        daily_payments = [
            p for p in all_payments
            if (p.created_at and p.created_at.strftime("%Y-%m-%d") == business_date_str)
            or (p.order_id in settled_order_ids_set)
        ]

        pay_map: dict[tuple[str, str | None], dict[str, int]] = {}
        for p in daily_payments:
            key = (p.method, p.provider)
            if key not in pay_map:
                pay_map[key] = {"count": 0, "total": 0}
            pay_map[key]["count"] += 1
            pay_map[key]["total"] += p.amount_xof

        payments_by_method = [
            PaymentMethodSplit(
                method=m,
                provider=prov,
                count=data["count"],
                total_amount_xof=data["total"],
            )
            for (m, prov), data in pay_map.items()
        ]

        # 3. Top Produits vendus
        settled_order_ids = [o.id for o in settled_orders_list]
        top_products: list[TopProductReport] = []
        if settled_order_ids:
            daily_items = (
                self.db.query(OrderItem)
                .filter(
                    OrderItem.order_id.in_(settled_order_ids),
                    OrderItem.removed_at.is_(None),
                )
                .all()
            )

            prod_map: dict[str, dict[str, Any]] = {}
            for item in daily_items:
                pid = item.product_id or "UNKNOWN"
                if pid not in prod_map:
                    prod_map[pid] = {
                        "name": item.product_name_snapshot,
                        "category": item.category_snapshot,
                        "qty": 0.0,
                        "revenue": 0,
                    }
                prod_map[pid]["qty"] += float(item.quantity)
                prod_map[pid]["revenue"] += item.line_total_xof

            sorted_prods = sorted(prod_map.items(), key=lambda x: x[1]["revenue"], reverse=True)[:10]
            top_products = [
                TopProductReport(
                    product_id=pid,
                    product_name=data["name"],
                    category_name=data.get("category"),
                    quantity_sold=data["qty"],
                    total_revenue_xof=data["revenue"],
                )
                for pid, data in sorted_prods
            ]

        # 4. Sessions actives
        active_sessions_count = (
            self.db.query(func.count(CashSession.id))
            .filter(CashSession.status == "OPEN")
            .scalar()
            or 0
        )

        # 5. Articles en alerte stock
        low_stock_items_count = (
            self.db.query(func.count(StockArticle.id))
            .filter(StockArticle.quantity <= StockArticle.alert_threshold)
            .scalar()
            or 0
        )

        # 6. FNE KPIs
        daily_order_ids_set = {o.id for o in daily_orders}
        all_fne_docs = self.db.query(FneDocument).all()
        daily_fne_docs = [
            d
            for d in all_fne_docs
            if (d.created_at and d.created_at.strftime("%Y-%m-%d") == business_date_str)
            or (d.certified_at and d.certified_at.strftime("%Y-%m-%d") == business_date_str)
            or (d.order_id and d.order_id in daily_order_ids_set)
        ]

        fne_certified_count = sum(
            1 for d in daily_fne_docs if d.status in ("CERTIFIED", "MANUAL_EXPORTED")
        )

        fne_pending_count = sum(
            1 for d in daily_fne_docs if d.status in ("QUEUED", "PENDING", "FAILED")
        )

        open_session = (
            self.db.query(CashSession)
            .filter(CashSession.status == "OPEN")
            .first()
        )

        latest_closed_session = (
            self.db.query(CashSession)
            .filter(CashSession.status == "CLOSED")
            .order_by(CashSession.closed_at.desc())
            .first()
        )

        closing_status: ClosingStatusResponse
        if open_session:
            closing_status = ClosingStatusResponse(
                is_closed=False,
                session_id=open_session.id,
            )
        elif latest_closed_session:
            closed_by_name = None
            if latest_closed_session.closed_by_user_id:
                u = self.db.query(User).filter(User.id == latest_closed_session.closed_by_user_id).first()
                if u:
                    closed_by_name = u.full_name
            closing_status = ClosingStatusResponse(
                is_closed=True,
                closed_at=latest_closed_session.closed_at.isoformat() if latest_closed_session.closed_at else None,
                closed_by_name=closed_by_name,
                session_id=latest_closed_session.id,
                z_number=latest_closed_session.z_number,
            )
        else:
            closing_status = ClosingStatusResponse(
                is_closed=True,
                closed_at=None,
                closed_by_name=None,
            )

        # 8. Ventes par caissier
        cashier_map: dict[str, dict[str, Any]] = {}
        for o in settled_orders_list:
            user_obj = o.closed_by or o.opened_by
            cashier_name = user_obj.full_name if user_obj else None
            if not cashier_name and o.closed_by_user_id:
                u = self.db.query(User).filter(User.id == o.closed_by_user_id).first()
                if u:
                    cashier_name = u.full_name
            if not cashier_name and o.opened_by_user_id:
                u = self.db.query(User).filter(User.id == o.opened_by_user_id).first()
                if u:
                    cashier_name = u.full_name
            if not cashier_name and open_session:
                sess_user = open_session.opened_by or (
                    self.db.query(User).filter(User.id == open_session.opened_by_user_id).first()
                    if open_session.opened_by_user_id else None
                )
                if sess_user:
                    cashier_name = sess_user.full_name

            cashier_name = cashier_name or "Caissier"
            if cashier_name not in cashier_map:
                cashier_map[cashier_name] = {
                    "cashier_name": cashier_name,
                    "orders_count": 0,
                    "total_sales_ttc_xof": 0,
                }
            cashier_map[cashier_name]["orders_count"] += 1
            cashier_map[cashier_name]["total_sales_ttc_xof"] += o.total_ttc_xof

        if not cashier_map and open_session:
            sess_user = open_session.opened_by or (
                self.db.query(User).filter(User.id == open_session.opened_by_user_id).first()
                if open_session.opened_by_user_id else None
            )
            name = sess_user.full_name if sess_user else "Caissier en service"
            cashier_map[name] = {
                "cashier_name": name,
                "orders_count": 0,
                "total_sales_ttc_xof": 0,
            }

        sales_by_cashier = [
            CashierSalesResponse(
                cashier_name=data["cashier_name"],
                orders_count=data["orders_count"],
                total_sales_ttc_xof=data["total_sales_ttc_xof"],
            )
            for data in sorted(cashier_map.values(), key=lambda x: x["total_sales_ttc_xof"], reverse=True)
        ]

        return DashboardKpiResponse(
            business_date=business_date_str,
            total_orders=total_orders,
            settled_orders=settled_orders,
            open_orders=open_orders,
            active_tables_count=active_tables_count,
            total_tables_count=total_tables_count,
            dine_in_orders_count=dine_in_orders_count,
            takeaway_orders_count=takeaway_orders_count,
            total_sales_ttc_xof=total_sales_ttc,
            total_sales_ht_xof=total_sales_ht,
            total_sales_vat_xof=total_sales_vat,
            average_basket_xof=avg_basket,
            payments_by_method=payments_by_method,
            top_products=top_products,
            hourly_sales=hourly_sales,
            active_sessions_count=active_sessions_count,
            low_stock_items_count=low_stock_items_count,
            fne_certified_count=fne_certified_count,
            fne_pending_count=fne_pending_count,
            closing_status=closing_status,
            sales_by_cashier=sales_by_cashier,
        )
