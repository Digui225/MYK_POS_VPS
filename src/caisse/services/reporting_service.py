"""Tableaux de bord de l'administrateur (01-BACKEND §5.8) : ventes et stock sur une période.

Lecture seule. Le coût matière vient des mouvements de vente (fiches techniques, au coût
moyen du moment de la vente) ; la consommation des articles suivis par inventaire et les
écarts viennent des inventaires et des pertes de la période.
"""

import uuid
from collections import defaultdict
from datetime import date
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy.orm import Session

from caisse.domain import stock_rules
from caisse.domain.enums import StockMovementType, StockOutMode
from caisse.errors import ValidationError
from caisse.models.stock import StockArticle
from caisse.repositories import fne as fne_repo
from caisse.repositories import reports as reports_repo
from caisse.repositories import stock as stock_repo
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
    YieldArticle,
    YieldProduct,
    YieldReportOut,
    YieldTotals,
)

MAX_DAYS = 366
_ZERO = Decimal(0)
_CENT = Decimal("0.01")

# mouvements par article et par type sur la période : (quantité, valeur) signées
Flows = dict[tuple[uuid.UUID, StockMovementType], tuple[Decimal, Decimal]]
COUNT_TYPES = (StockMovementType.INVENTORY_COUNT, StockMovementType.ADJUSTMENT)


def _xof(value: Decimal) -> int:
    return int(value.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def _r2(value: Decimal) -> float:
    return float(value.quantize(_CENT, rounding=ROUND_HALF_UP))


def _flow_qty(period: Flows, article_id: uuid.UUID, *types: StockMovementType) -> Decimal:
    return sum((period.get((article_id, t), (_ZERO, _ZERO))[0] for t in types), _ZERO)


def _opening_closing(
    article: StockArticle, period: Flows, after: dict[uuid.UUID, Decimal]
) -> tuple[Decimal, Decimal]:
    """Stock de début et de fin de période, recalculés depuis le journal : le début d'une
    journée est la fin de la veille. Le stock de départ saisi pendant la période compte
    dans le début."""
    closing = article.quantity - after.get(article.id, _ZERO)
    in_period = sum(
        (
            q
            for (aid, t), (q, _) in period.items()
            if aid == article.id and t != StockMovementType.OPENING
        ),
        _ZERO,
    )
    return closing - in_period, closing


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
                product_id=pid,
                name=name,
                category=category,
                quantity=quantity,
                revenue_xof=revenue,
                has_recipe=pid in recipes,
                recipe_cost_xof=cost,
                recipe_margin_xof=revenue - cost,
            )
        )
        bucket = categories[category]
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
                id=s.id,
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
    moved: set[uuid.UUID] = {aid for aid, _ in period}
    articles = [
        a for a in stock_repo.list_articles(db, is_active=None) if a.is_active or a.id in moved
    ]

    def qty(aid: uuid.UUID, *types: StockMovementType) -> Decimal:
        return _flow_qty(period, aid, *types)

    def value(aid: uuid.UUID, *types: StockMovementType) -> Decimal:
        return sum((period.get((aid, t), (_ZERO, _ZERO))[1] for t in types), _ZERO)

    sale_types = (StockMovementType.SALE_OUT, StockMovementType.RETURN_IN)
    count_types = COUNT_TYPES
    out_types = (*sale_types, StockMovementType.LOSS_OUT, *count_types)

    rows: list[StockReportArticle] = []
    totals: defaultdict[str, Decimal] = defaultdict(lambda: _ZERO)
    for a in articles:
        opening, closing = _opening_closing(a, period, after)
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
                article_id=a.id,
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


def yield_report(db: Session, date_from: date, date_to: date) -> YieldReportOut:
    """Rendement des fiches (le « rapport bœuf ») : pour chaque article à fiche, les plats que
    la quantité consommée aurait dû donner, les plats vendus à la caisse, l'écart en plats et
    au prix de vente moyen.

    Consommé = début + entrées - fin, d'après le journal. Sans inventaire dans la période, la
    fin est le stock prévu : l'écart se limite alors aux pertes déclarées. Avec un inventaire
    par semaine, choisir la période du lendemain d'un inventaire au jour du suivant."""
    check_period(date_from, date_to)
    period: Flows = reports_repo.movements_by_article_type(db, date_from, date_to)
    after = reports_repo.quantity_after(db, date_to)
    counts = reports_repo.last_count_dates(db, date_to)
    sales: defaultdict[uuid.UUID, list[tuple[uuid.UUID, str, Decimal, int, int]]] = defaultdict(
        list
    )
    for aid, pid, name, qty, dishes, revenue in reports_repo.sales_by_article_product(
        db, date_from, date_to
    ):
        sales[aid].append((pid, name, qty, dishes, revenue))
    recipes: defaultdict[uuid.UUID, list[tuple[uuid.UUID, str, Decimal, int]]] = defaultdict(list)
    for aid, pid, name, qty, price in reports_repo.recipe_dishes(db):
        recipes[aid].append((pid, name, qty, price))

    rows: list[YieldArticle] = []
    for a in stock_repo.list_articles(db, is_active=None):
        if a.out_mode != StockOutMode.RECIPE or (a.id not in sales and a.id not in recipes):
            continue
        opening, closing = _opening_closing(a, period, after)
        purchased = _flow_qty(period, a.id, StockMovementType.PURCHASE_IN)
        loss = -_flow_qty(period, a.id, StockMovementType.LOSS_OUT)
        adjustment = _flow_qty(period, a.id, *COUNT_TYPES)
        consumed = opening + purchased - closing

        sold = sales.get(a.id, [])
        sold_qty = sum((qty for _, _, qty, _, _ in sold), _ZERO)
        sold_portions = sum(dishes for _, _, _, dishes, _ in sold)
        sold_xof = sum(revenue for *_, revenue in sold)
        recipe = recipes.get(a.id, [])
        if sold_portions > 0:
            portion = sold_qty / sold_portions
            average_price = Decimal(sold_xof) / sold_portions
        else:  # aucune vente : fiches et prix actuels
            portion = sum((qty for _, _, qty, _ in recipe), _ZERO) / len(recipe)
            average_price = Decimal(sum(price for *_, price in recipe)) / len(recipe)
        if portion <= 0:
            continue
        expected = consumed / portion
        variance = expected - sold_portions
        unexplained = -adjustment / portion

        products = {
            pid: YieldProduct(
                product_id=pid,
                name=name,
                portion_quantity=_r2(qty / dishes) if dishes else 0.0,
                quantity=dishes,
                revenue_xof=revenue,
            )
            for pid, name, qty, dishes, revenue in sold
        }
        for pid, name, qty, _ in recipe:
            if pid not in products:
                products[pid] = YieldProduct(
                    product_id=pid, name=name, portion_quantity=_r2(qty), quantity=0, revenue_xof=0
                )
        rows.append(
            YieldArticle(
                article_id=a.id,
                name=a.name,
                category=a.category,
                unit=a.unit,
                counted_in_period=any((a.id, t) in period for t in COUNT_TYPES),
                last_count_date=counts.get(a.id),
                opening_quantity=_r2(opening),
                purchased_quantity=_r2(purchased),
                closing_quantity=_r2(closing),
                consumed_quantity=_r2(consumed),
                portion_quantity=_r2(portion),
                expected_portions=_r2(expected),
                sold_portions=sold_portions,
                portion_variance=_r2(variance),
                loss_portions=_r2(loss / portion),
                unexplained_portions=_r2(unexplained),
                sold_xof=sold_xof,
                average_price_xof=_xof(average_price),
                variance_xof=_xof(variance * average_price),
                unexplained_xof=_xof(unexplained * average_price),
                products=sorted(products.values(), key=lambda p: (-p.quantity, p.name)),
            )
        )
    rows.sort(key=lambda r: (-r.variance_xof, r.name))
    return YieldReportOut(
        date_from=date_from,
        date_to=date_to,
        totals=YieldTotals(
            sold_xof=sum(r.sold_xof for r in rows),
            variance_xof=sum(r.variance_xof for r in rows),
            unexplained_xof=sum(r.unexplained_xof for r in rows),
            articles_counted=sum(1 for r in rows if r.counted_in_period),
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
            DashboardProduct(product_id=pid, name=name, quantity=qty, revenue_xof=total)
            for pid, name, _, qty, total in top
        ],
        hourly=[
            DashboardHour(hour=h, orders_count=n, revenue_xof=total)
            for h, n, total in reports_repo.sales_by_hour(db, day)
        ],
        by_cashier=[
            DashboardCashier(user_id=uid, full_name=name, orders_count=n, revenue_xof=total)
            for uid, name, n, total in reports_repo.sales_by_closer(db, day)
        ],
        sessions=[
            DashboardSession(
                id=s.id,
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
